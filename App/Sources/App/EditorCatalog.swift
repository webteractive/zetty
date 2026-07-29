import AppKit
import ZettyCore

/// Detection + resolution of GUI editors, shared by Settings' config opener
/// and the status bar's "open project in editor" control.
enum EditorCatalog {

    /// Curated roster of popular editors (bundle ids), in display order. Only
    /// the installed subset is offered — apps like browsers that merely
    /// *register* for text files stay out. The `editor` config key remains the
    /// escape hatch for anything not listed.
    static let knownBundleIDs: [String] = [
        "dev.zed.Zed",                       // Zed
        "com.microsoft.VSCode",              // Visual Studio Code
        "com.todesktop.230313mzl4w4u92",     // Cursor
        "com.exafunction.windsurf",          // Windsurf
        "com.sublimetext.4",                 // Sublime Text 4
        "com.sublimetext.3",                 // Sublime Text 3
        "com.barebones.bbedit",              // BBEdit
        "com.macromates.TextMate",           // TextMate
        "com.panic.Nova",                    // Nova
        "com.jetbrains.fleet",               // Fleet
        "com.apple.dt.Xcode",                // Xcode
        "com.apple.TextEdit",                // TextEdit
    ]

    /// The installed subset of the roster, deduped by display name.
    static func installed() -> [URL] {
        var seen = Set<String>()
        return knownBundleIDs
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .filter { seen.insert(displayName(of: $0).lowercased()).inserted }
    }

    static func displayName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// True if the app at `url` is the one the `editor` config value names.
    static func matches(_ url: URL, editor: String) -> Bool {
        displayName(of: url).caseInsensitiveCompare(editor) == .orderedSame
            || Bundle(url: url)?.bundleIdentifier?.caseInsensitiveCompare(editor) == .orderedSame
    }

    /// Resolves an `editor` value to an app URL: bundle id first, then an app
    /// name looked up in the standard Applications folders.
    static func resolve(_ editor: String) -> URL? {
        let trimmed = editor.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return url
        }
        let name = trimmed.hasSuffix(".app") ? trimmed : trimmed + ".app"
        let candidates = [
            "/Applications/\(name)",
            "\(NSHomeDirectory())/Applications/\(name)",
            "/System/Applications/\(name)",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// The app's real icon, sized for inline UI.
    static func icon(for url: URL, size: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    /// The URL that opens `file` at `line` in the editor at `url`, or nil when
    /// that editor has no line-addressing scheme (open the file plainly then).
    static func openURL(for editor: URL, file: String, line: Int?, column: Int?) -> URL? {
        guard let bundleID = Bundle(url: editor)?.bundleIdentifier else { return nil }
        return EditorURLScheme.url(bundleID: bundleID, file: file, line: line, column: column)
    }
}
