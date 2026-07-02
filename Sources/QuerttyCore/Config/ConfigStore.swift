import Foundation

/// Reads (and, on first launch, seeds) Zetty's config file.
///
/// Location, ghostty-style: `$XDG_CONFIG_HOME/zetty/config` when
/// `XDG_CONFIG_HOME` is set, otherwise `~/.config/zetty/config`. A pre-rename
/// `…/quertty/config` is migrated (moved) the first time the new path is
/// resolved and doesn't exist yet.
public struct ConfigStore {

    public let fileURL: URL

    /// - Parameter fileURL: Override the resolved path (used by tests). When
    ///   `nil`, the standard XDG / `~/.config` location is used.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true)
        }
        self.fileURL = base
            .appendingPathComponent("zetty", isDirectory: true)
            .appendingPathComponent("config")

        // One-time migration from the pre-rename location.
        let legacyURL = base
            .appendingPathComponent("quertty", isDirectory: true)
            .appendingPathComponent("config")
        let fm = FileManager.default
        if !fm.fileExists(atPath: self.fileURL.path), fm.fileExists(atPath: legacyURL.path) {
            try? fm.createDirectory(at: self.fileURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.moveItem(at: legacyURL, to: self.fileURL)
        }
    }

    /// Loads the config. If the file is missing, writes the documented default
    /// (best-effort) and returns `AppConfig()` defaults. A present-but-unreadable
    /// file also falls back to defaults without throwing.
    public func load() -> AppConfig {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            return AppConfig.parse(text)
        }
        writeDefaultIfMissing()
        return AppConfig()
    }

    /// Persists `config` to disk in the documented format (best-effort). Used
    /// when the app changes a setting at runtime (e.g. the scheme switcher).
    public func save(_ config: AppConfig) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? config.rendered().write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Writes the starter config only when no file exists yet. Errors (sandbox,
    /// read-only home) are swallowed — a missing config simply means defaults.
    public func writeDefaultIfMissing() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? AppConfig.defaultFileContents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
