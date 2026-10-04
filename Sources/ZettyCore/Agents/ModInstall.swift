import Foundation

/// The rules for shipping Zetty's Claude Code mod. Pure: `ModInstaller` does
/// the copying and `AppDelegate` sets the variable.
///
/// The mod is loaded from a COPY under `~/.zetty/mods`, never from inside the
/// app bundle: Claude Code writes type declarations beside any mod it loads,
/// and writing into `zetty.app` would break its signature.
public enum ModInstall {

    public static let name = "zetty-bridge"

    /// The variable Claude Code reads plugin folders from where no
    /// `--plugin-dir` flag can be given.
    public static let pluginDirsVariable = "CLAUDE_CODE_PLUGIN_DIRS"

    /// The app binary, which doubles as the control CLI. The mod runs it for
    /// everything it asks of Zetty, so it never depends on the optional
    /// `~/.local/bin/zetty` symlink or on `PATH`.
    public static let binaryVariable = "ZETTY_BIN"

    /// `"0"` when `zetty-claude-tools` is off; the mod then registers no tools
    /// for the model. Anything else, unset included, is on.
    public static let toolsVariable = "ZETTY_CLAUDE_TOOLS"

    /// `~/.zetty/mods/zetty-bridge`.
    public static func installedPath(home: String) -> String {
        "\(home)/.zetty/mods/\(name)"
    }

    /// The `version` a `.claude-plugin/plugin.json` declares.
    public static func version(manifest: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        return object?["version"] as? String
    }

    /// Whether the bundled mod must be copied out. Any difference counts, a
    /// downgrade included: the installed copy has to match the app that reads
    /// its snapshots.
    public static func needsInstall(bundled: Data?, installed: Data?) -> Bool {
        guard let bundled, let wanted = version(manifest: bundled) else { return false }
        guard let installed else { return true }
        return version(manifest: installed) != wanted
    }

    /// The value for `pluginDirsVariable`: `existing` with the mod's folder
    /// added last, or taken out when the integration is off. nil means the
    /// variable should be unset.
    ///
    /// Idempotent, so a reload never stacks the path, and it keeps a folder
    /// the user listed themselves.
    public static func pluginDirs(existing: String?, modPath: String, enabled: Bool) -> String? {
        var paths = (existing ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != modPath }
        if enabled { paths.append(modPath) }
        return paths.isEmpty ? nil : paths.joined(separator: ":")
    }
}
