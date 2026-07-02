import Foundation
import ZettyCore

/// Installs/uninstalls Zetty's agent hooks into each harness's config.
///
/// Writes the shared Python hook helper, then applies the pure `*HookConfig`
/// transforms to the harness config file. Only touches a config when the user
/// explicitly triggers install/uninstall. Codex's original `notify` line is
/// backed up so uninstall restores it verbatim.
final class HookInstaller {

    enum Outcome {
        case installed
        case uninstalled
        case alreadyInstalled
        case conflict(snippet: String)   // Hermes: a non-Zetty hooks: block exists
        case failed(String)
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// Deliberately still under `~/.quertty/` — that path is EMBEDDED in the
    /// harness configs of every existing install, and `~/.quertty` is kept as
    /// a symlink to `~/.zetty` by the startup migration, so old and new
    /// installs resolve to the same script.
    var scriptURL: URL {
        home.appendingPathComponent(".quertty/hooks/\(AgentHookScript.fileName)")
    }
    private var codexBackupURL: URL {
        home.appendingPathComponent(".quertty/codex-notify-backup")
    }

    private func configURL(_ harness: Harness) -> URL {
        switch harness {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex:  return home.appendingPathComponent(".codex/config.toml")
        case .hermes: return home.appendingPathComponent(".hermes/config.yaml")
        }
    }

    // MARK: - Status

    func isInstalled(_ harness: Harness) -> Bool {
        let path = scriptURL.path
        guard let text = try? String(contentsOf: configURL(harness), encoding: .utf8) else { return false }
        switch harness {
        case .claude:
            guard let dict = jsonObject(from: text) else { return false }
            return ClaudeHookConfig.isInstalled(in: dict, scriptPath: path)
        case .codex:
            return CodexHookConfig.isInstalled(configText: text, scriptPath: path)
        case .hermes:
            return HermesHookConfig.isInstalled(configText: text)
        }
    }

    // MARK: - Install

    func install(_ harness: Harness) -> Outcome {
        do {
            try ensureScript()
            let path = scriptURL.path
            let url = configURL(harness)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )

            switch harness {
            case .claude:
                let dict = ClaudeHookConfig.install(into: jsonObject(from: url) ?? [:], scriptPath: path)
                try writeJSON(dict, to: url)
                return .installed

            case .codex:
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                switch CodexHookConfig.install(configText: text, scriptPath: path) {
                case .alreadyInstalled:
                    return .alreadyInstalled
                case let .updated(newText, backup):
                    try newText.write(to: url, atomically: true, encoding: .utf8)
                    try backup.write(to: codexBackupURL, atomically: true, encoding: .utf8)
                    return .installed
                }

            case .hermes:
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                switch HermesHookConfig.install(configText: text, scriptPath: path) {
                case let .updated(newText):
                    try newText.write(to: url, atomically: true, encoding: .utf8)
                    return .installed
                case let .conflict(snippet):
                    return .conflict(snippet: snippet)
                }
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Uninstall

    func uninstall(_ harness: Harness) -> Outcome {
        let url = configURL(harness)
        guard FileManager.default.fileExists(atPath: url.path) else { return .uninstalled }
        do {
            let path = scriptURL.path
            switch harness {
            case .claude:
                guard let dict = jsonObject(from: url) else { return .uninstalled }
                try writeJSON(ClaudeHookConfig.uninstall(from: dict, scriptPath: path), to: url)

            case .codex:
                let text = try String(contentsOf: url, encoding: .utf8)
                let backup = (try? String(contentsOf: codexBackupURL, encoding: .utf8)) ?? ""
                let newText = CodexHookConfig.uninstall(configText: text, backup: backup, scriptPath: path)
                try newText.write(to: url, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: codexBackupURL)

            case .hermes:
                let text = try String(contentsOf: url, encoding: .utf8)
                try HermesHookConfig.uninstall(configText: text).write(to: url, atomically: true, encoding: .utf8)
            }
            return .uninstalled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func ensureScript() throws {
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try AgentHookScript.contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Rewrites the hook script with the current version if it's already
    /// installed, so script fixes reach existing installs without re-toggling.
    func refreshInstalledScriptIfPresent() {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return }
        try? ensureScript()
    }

    private func jsonObject(from url: URL) -> [String: Any]? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(jsonObject(from:))
    }

    private func jsonObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return dict
    }

    private func writeJSON(_ dict: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }
}
