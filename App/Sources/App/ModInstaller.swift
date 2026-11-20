import Foundation
import ZettyCore

/// Copies Zetty's bundled Claude Code mod out to `~/.zetty/mods` and points
/// Claude Code at it. The rules — when to copy, what the variable holds — are
/// the pure `ModInstall`.
struct ModInstaller {

    private let fileManager = FileManager.default

    private var installedURL: URL {
        URL(fileURLWithPath: ModInstall.installedPath(home: NSHomeDirectory()), isDirectory: true)
    }

    /// `Contents/Resources/Mods/zetty-bridge`, nil in a build without it.
    private var bundledURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("Mods", isDirectory: true)
            .appendingPathComponent(ModInstall.name, isDirectory: true)
    }

    private func manifest(in root: URL) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(".claude-plugin/plugin.json"))
    }

    /// Brings the installed copy up to the bundled version. Returns whether a
    /// usable copy is in place afterwards.
    ///
    /// Files are overwritten one by one rather than the folder replaced: a
    /// running Claude watches this folder and reloads the mod when it settles,
    /// and deleting it first would hand that session a missing module.
    @discardableResult
    func installIfNeeded() -> Bool {
        guard let bundled = bundledURL, let bundledManifest = manifest(in: bundled) else {
            return manifest(in: installedURL) != nil
        }
        guard ModInstall.needsInstall(bundled: bundledManifest,
                                      installed: manifest(in: installedURL)) else { return true }
        do {
            try copyTree(from: bundled, to: installedURL)
            return true
        } catch {
            ZettyLog.lifecycle.log("mod: install failed: \(error.localizedDescription)")
            return manifest(in: installedURL) != nil
        }
    }

    /// The manifest goes LAST: it carries the version `needsInstall` reads, so
    /// a copy cut short is retried at the next launch instead of passing as
    /// current.
    private func copyTree(from source: URL, to destination: URL) throws {
        let manifestPath = ".claude-plugin/plugin.json"
        guard let enumerator = fileManager.enumerator(atPath: source.path) else { return }
        var files: [String] = []
        for case let relative as String in enumerator {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: source.appendingPathComponent(relative).path,
                                   isDirectory: &isDirectory)
            // The tests are for the repo; a session has no use for them.
            guard !isDirectory.boolValue, !relative.hasPrefix("tests/"),
                  relative != manifestPath else { continue }
            files.append(relative)
        }
        func copy(_ relative: String) throws {
            let target = destination.appendingPathComponent(relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try Data(contentsOf: source.appendingPathComponent(relative))
                .write(to: target, options: .atomic)
        }
        // New files first, then the sweep, then the manifest: a running Claude
        // watching this folder never sees `hooks.json` name a module that is
        // not there yet.
        for relative in files { try copy(relative) }
        // Source files a newer mod no longer has: a renamed module left behind
        // (register.ts beside register.tsx) is dead weight the engine may still
        // read. Only the mod's own
        // folders are swept — `.claude-plugin/types` and `tsconfig.json` are
        // Claude Code's, laid beside the mod every time it loads.
        let shipped = Set(files)
        for folder in ["hooks", "types"] {
            let root = destination.appendingPathComponent(folder)
            guard let installed = fileManager.enumerator(atPath: root.path) else { continue }
            for case let name as String in installed {
                let relative = "\(folder)/\(name)"
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: root.appendingPathComponent(name).path,
                                       isDirectory: &isDirectory)
                if !isDirectory.boolValue, !shipped.contains(relative) {
                    try? fileManager.removeItem(at: root.appendingPathComponent(name))
                }
            }
        }
        try copy(manifestPath)
    }

    /// Puts the mod into (or takes it out of) the plugin list a Claude
    /// `settings.json` names for itself, in each config dir (default and
    /// accounts). Claude applies that list over the process environment, so
    /// without this the mod loads in no pane. Rewrites a file only when it
    /// changes, and never creates one.
    func syncSettings(configDirectories: [String], enabled: Bool) {
        for directory in configDirectories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("settings.json")
            guard let data = try? Data(contentsOf: url),
                  let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let merged = ModInstall.settingsLoadingMod(settings, modPath: installedURL.path, enabled: enabled)
            guard !NSDictionary(dictionary: merged).isEqual(to: settings),
                  let out = try? JSONSerialization.data(
                      withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            else { continue }
            do {
                // Through a link to the real file (`LinkPreservingWrite`):
                // a dotfiles-linked settings.json stays linked.
                try LinkPreservingWrite.write(out, to: url)
                ZettyLog.lifecycle.log("mod: \(enabled ? "added to" : "removed from") plugin dirs in \(url.path)")
            } catch {
                ZettyLog.lifecycle.log("mod: could not update \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// The plugin-folder variable as Zetty inherited it, without the mod. Read
    /// once, by the first `applyEnvironment`.
    private var inheritedPluginDirs: String?
    private var inheritedPluginDirsRead = false

    /// The mod's variables for every pane spawned from now on, laid over the
    /// process environment by the app's surface environment provider. A
    /// running agent keeps what it started with.
    private(set) var paneEnvironment: [String: String] = [:]

    /// Recomputes `paneEnvironment`. Never touches the process environment
    /// after the first call, and that call runs before any pane exists.
    ///
    /// libghostty copies the `environ` pointer and its length once, in
    /// `ghostty_init`, and walks that copy for every pane it builds later. A
    /// `setenv` or `unsetenv` after that can move or shrink the array under it,
    /// and the next pane reads freed memory: turning the mod off and reloading
    /// crashed in `ghostty_config_finalize`, every time.
    mutating func applyEnvironment(enabled: Bool, tools: Bool) {
        let variable = ModInstall.pluginDirsVariable
        if !inheritedPluginDirsRead {
            inheritedPluginDirsRead = true
            inheritedPluginDirs = ModInstall.pluginDirs(
                existing: getenv(variable).map { String(cString: $0) },
                modPath: installedURL.path, enabled: false)
            // Safe only here, before the first pane and so before
            // ghostty_init: from now on panes get the value per pane, so a
            // reload that turns the mod off never needs an unsetenv.
            unsetenv(variable)
        }
        var environment: [String: String] = [:]
        if let binary = Bundle.main.executablePath {
            environment[ModInstall.binaryVariable] = binary
        }
        environment[ModInstall.toolsVariable] = tools ? "1" : "0"
        if let value = ModInstall.pluginDirs(
            existing: inheritedPluginDirs,
            modPath: installedURL.path,
            enabled: enabled && installIfNeeded()) {
            environment[variable] = value
        }
        paneEnvironment = environment
    }
}
