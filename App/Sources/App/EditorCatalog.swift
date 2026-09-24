import AppKit
import ZettyGhostty

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

    /// Cached because BOTH halves of building the menu are LaunchServices and
    /// IconServices round trips, and the menu is rebuilt on every click of
    /// every tile's Open button. Measured cold on a 12-entry roster with 3
    /// installed: 9.5 ms of bundle-id lookups and **138 ms of icon loading**,
    /// all on the main thread, all of it repeated per click. The icons are the
    /// cost, so caching only the URL list would fix almost nothing.
    ///
    /// Main-actor isolated rather than locked: every caller is AppKit menu
    /// construction (the tile header, the status bar, the viewer footer, the
    /// Settings popup), so there is no second thread to protect against.
    @MainActor private static var installedCache: [URL]?
    @MainActor private static var iconCache: [IconKey: NSImage] = [:]

    private struct IconKey: Hashable {
        let url: URL
        let size: CGFloat
    }

    /// The installed subset of the roster, deduped by display name.
    @MainActor static func installed() -> [URL] {
        if let installedCache { return installedCache }
        var seen = Set<String>()
        let found = knownBundleIDs
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .filter { seen.insert(displayName(of: $0).lowercased()).inserted }
        installedCache = found
        return found
    }

    /// Drops both caches, so an editor installed while Zetty runs appears
    /// without a relaunch. Wired to the config reload (⇧⌘,) because that is
    /// already the "pick up what changed underneath me" gesture — polling for
    /// newly installed apps would be the `git`-pill mistake again.
    @MainActor static func invalidate() {
        installedCache = nil
        iconCache.removeAll()
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

    /// The app's real icon, sized for inline UI. Keyed by size as well as URL
    /// — the menus ask for 16pt and the viewer footer for 14pt, and `size` is
    /// set on the returned image, so one cached instance cannot serve both.
    @MainActor static func icon(for url: URL, size: CGFloat) -> NSImage {
        let key = IconKey(url: url, size: size)
        if let cached = iconCache[key] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        iconCache[key] = icon
        return icon
    }

    /// The URL that opens `file` at `line` in the editor at `url`, or nil when
    /// that editor has no line-addressing scheme (open the file plainly then).
    static func openURL(for editor: URL, file: String, line: Int?, column: Int?) -> URL? {
        guard let bundleID = Bundle(url: editor)?.bundleIdentifier else { return nil }
        return EditorURLScheme.url(bundleID: bundleID, file: file, line: line, column: column)
    }
}
