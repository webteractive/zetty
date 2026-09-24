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

    /// Cached because BOTH halves of building the menu are system round
    /// trips, and the menu is rebuilt on every click of every tile's Open
    /// button. Measured on this machine: 9.5ms of LaunchServices bundle-id
    /// lookups and ~90-138ms of IconServices loading, all on the main thread,
    /// all repeated per click.
    ///
    /// **The icon objects are lazy, and that is the larger half.**
    /// `NSWorkspace.icon(forFile:)` returns a multi-representation icns —
    /// measured at **32 representations** per app — and nothing rasterises
    /// until something DRAWS it. For a menu that is when it appears, which is
    /// after the build returns: measured 60ms for the first draw of three
    /// icons and 0.2ms for every draw after. So a build-time measurement
    /// understates the click, and caching the URLs alone would fix almost
    /// nothing.
    ///
    /// Main-actor isolated rather than locked: every caller is AppKit menu
    /// construction (the tile header, the status bar, the viewer footer, the
    /// Settings popup), so there is no second thread to protect against.
    @MainActor private static var installedCache: [URL]?
    @MainActor private static var iconCache: [IconKey: NSImage] = [:]
    /// Double optional: the outer nil means "not looked up", the inner one
    /// means "looked up and genuinely absent" — without it a missing Finder
    /// would be re-queried on every click.
    @MainActor private static var finderCache: URL??
    @MainActor private static var priming = false

    /// The sizes the UI actually asks for: 16pt in the menus, 14pt in the
    /// viewer footer. `size` is set ON the image, so one instance cannot serve
    /// both and each size needs its own.
    static let iconSizes: [CGFloat] = [14, 16]

    private struct IconKey: Hashable {
        let url: URL
        let size: CGFloat
    }

    /// The installed subset of the roster, deduped by display name.
    @MainActor static func installed() -> [URL] {
        if let installedCache { return installedCache }
        let found = resolveInstalled()
        installedCache = found
        return found
    }

    /// The roster lookup with no cache and no actor requirement, so `prime`
    /// can run it off the main thread.
    private static func resolveInstalled() -> [URL] {
        var seen = Set<String>()
        return knownBundleIDs
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .filter { seen.insert(displayName(of: $0).lowercased()).inserted }
    }

    /// Finder, cached — it was the one LaunchServices call still made per
    /// click after the roster was cached.
    @MainActor static func finderApp() -> URL? {
        if let finderCache { return finderCache }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
        finderCache = .some(url)
        return url
    }

    /// Fills the caches OFF the click, because doing this work lazily means
    /// the first Open of every session pays for all of it at once.
    ///
    /// The lookups and the icon fetches are LaunchServices/IconServices IPC
    /// and run on a background queue (verified: a cold pass entirely off-main
    /// returns valid, correctly sized images). The warming draw has to be on
    /// main — it needs a graphics context — but that is the cheap half, and
    /// it happens once at launch rather than under a pointer.
    @MainActor static func prime() {
        guard installedCache == nil, !priming else { return }
        priming = true
        DispatchQueue.global(qos: .utility).async {
            let urls = resolveInstalled()
            let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
            // One image PER SIZE: `size` is a property of the instance.
            var fetched: [(IconKey, NSImage)] = []
            for url in urls + (finder.map { [$0] } ?? []) {
                for size in iconSizes {
                    let image = NSWorkspace.shared.icon(forFile: url.path)
                    image.size = NSSize(width: size, height: size)
                    fetched.append((IconKey(url: url, size: size), image))
                }
            }
            DispatchQueue.main.async {
                installedCache = urls
                finderCache = .some(finder)
                for (key, image) in fetched {
                    warm(image, size: key.size)
                    iconCache[key] = image
                }
                priming = false
            }
        }
    }

    /// Forces the 32-representation icns to rasterise now, by drawing it once
    /// into a scratch bitmap. The image caches that internally, so the menu's
    /// own draw is the 0.2ms case instead of the 60ms one. The scratch bitmap
    /// is discarded — the point is the side effect, and keeping the original
    /// image means no representation is lost and nothing renders soft on a
    /// Retina display.
    @MainActor private static func warm(_ image: NSImage, size: CGFloat) {
        let box = NSSize(width: size, height: size)
        let scratch = NSImage(size: box)
        scratch.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: box))
        scratch.unlockFocus()
    }

    /// Drops every cache, so an editor installed while Zetty runs appears
    /// without a relaunch. Wired to the config reload (⇧⌘,) because that is
    /// already the "pick up what changed underneath me" gesture — polling for
    /// newly installed apps would be the `git`-pill mistake again.
    @MainActor static func invalidate() {
        installedCache = nil
        iconCache.removeAll()
        finderCache = nil
        prime()
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

    /// The app's real icon, sized for inline UI. Keyed by size as well as URL,
    /// and warmed on the way into the cache so the caller's first draw is not
    /// the one that rasterises it. `prime` normally fills this first; this
    /// path is the fallback when something asks before priming finishes.
    @MainActor static func icon(for url: URL, size: CGFloat) -> NSImage {
        let key = IconKey(url: url, size: size)
        if let cached = iconCache[key] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        warm(icon, size: size)
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
