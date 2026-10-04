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

    /// Sets (or clears) the plugin-folder variable for every pane spawned from
    /// now on. A running agent keeps what it started with.
    func applyEnvironment(enabled: Bool, tools: Bool) {
        if let binary = Bundle.main.executablePath {
            setenv(ModInstall.binaryVariable, binary, 1)
        }
        setenv(ModInstall.toolsVariable, tools ? "1" : "0", 1)
        let variable = ModInstall.pluginDirsVariable
        let value = ModInstall.pluginDirs(
            existing: getenv(variable).map { String(cString: $0) },
            modPath: installedURL.path,
            enabled: enabled && installIfNeeded())
        if let value {
            setenv(variable, value, 1)
        } else {
            unsetenv(variable)
        }
    }
}
