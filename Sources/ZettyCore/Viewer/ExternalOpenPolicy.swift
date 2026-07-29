import Foundation

/// Decides whether a non-text file may be handed to the system's default app or
/// should only be revealed in Finder.
///
/// This exists because the viewer's input is **untrusted**: a path can come from
/// arbitrary terminal output (a log, a `curl` response), and ⌘-click turns
/// reading that output into "ask LaunchServices to open this". Displaying a
/// document is harmless; installing or executing one is not.
///
/// Most of the dangerous surface is already closed elsewhere — shell scripts are
/// text, so they render in the viewer, and `.app`/`.workflow` bundles are
/// directories, which the viewer refuses outright. What reaches this policy is
/// the remainder: installers, archives that auto-run, and compiled binaries.
/// Those get revealed rather than launched, so the user stays one deliberate
/// double-click away from running anything.
public enum ExternalOpenPolicy {

    public enum Decision: Equatable, Sendable {
        /// Safe to hand to the default app (a PDF to Preview, a PNG to an image viewer).
        case openWithDefaultApp
        /// Show it in Finder instead — opening it would install or execute something.
        case revealInFinder
    }

    /// Extensions macOS installs, mounts, or executes rather than displays.
    /// Bundle types are listed too even though directories never get this far —
    /// cheap insurance if that guard ever moves.
    static let neverLaunchExtensions: Set<String> = [
        "pkg", "mpkg", "dmg", "iso", "xip",              // installers & disk images
        "jar", "class",                                   // JVM
        "app", "bundle", "kext", "plugin", "framework",   // bundles
        "prefpane", "saver", "wdgt", "appex",
        "scpt", "scptd", "applescript", "osascript",      // scripts
        "workflow", "action", "shortcut",
        "command", "tool", "exe", "msi", "bat", "com",
    ]

    /// Mach-O and universal-binary magic numbers, both byte orders. `CAFEBABE`
    /// doubles as Java's `.class` magic — either way, revealing is correct.
    static let executableMagics: [[UInt8]] = [
        [0xCF, 0xFA, 0xED, 0xFE],   // Mach-O 64, little-endian
        [0xCE, 0xFA, 0xED, 0xFE],   // Mach-O 32, little-endian
        [0xFE, 0xED, 0xFA, 0xCF],   // Mach-O 64, big-endian
        [0xFE, 0xED, 0xFA, 0xCE],   // Mach-O 32, big-endian
        [0xCA, 0xFE, 0xBA, 0xBE],   // universal ("fat") binary / Java class
        [0xBE, 0xBA, 0xFE, 0xCA],   // fat, byte-swapped
    ]

    /// `header` is the start of the file (the first few bytes are enough).
    public static func decision(path: String, header: Data) -> Decision {
        let ext = (path as NSString).pathExtension.lowercased()
        if neverLaunchExtensions.contains(ext) { return .revealInFinder }
        if isExecutable(header) { return .revealInFinder }
        return .openWithDefaultApp
    }

    static func isExecutable(_ header: Data) -> Bool {
        let bytes = [UInt8](header.prefix(4))
        guard bytes.count == 4 else { return false }
        return executableMagics.contains(bytes)
    }
}
