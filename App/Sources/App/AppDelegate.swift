import AppKit
import GhosttyTerminal
import QuerttyCore

/// Window that gives the app's main-menu key equivalents (⌘D / ⇧⌘D / ⌘W)
/// priority over the focused view. The embedded GhosttyTerminal view otherwise
/// consumes those key equivalents (AppKit hands the view hierarchy first crack),
/// so menu shortcuts never fire. Checking the main menu before `super` (which
/// forwards to the view hierarchy) restores the expected app-shortcut behaviour.
final class QuerttyWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// NOTE: no `@main` here. Tuist's default macOS Info.plist sets
// NSMainStoryboardFile = "Main", and `@main` on an NSApplicationDelegate routes
// through NSApplicationMain, which eagerly loads that (nonexistent) storyboard
// and crashes before the delegate runs. We bootstrap NSApplication manually in
// main.swift instead, which never consults the storyboard key.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaultContentSize = NSSize(width: 920, height: 560)
    private let minimumContentSize = NSSize(width: 600, height: 320)
    private var window: NSWindow?

    /// Strong reference to the terminal view controller so it survives until
    /// `applicationWillTerminate` (the window — and thus its contentViewController —
    /// is released on last-window-close, BEFORE terminate; a weak ref would be nil
    /// at save time and the workspace would never persist).
    private var terminalViewController: TerminalViewController?

    /// The persistent workspace store backed by `~/Library/Application Support/quertty/`.
    private lazy var workspaceStore: WorkspaceStore = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("quertty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WorkspaceStore(directory: dir)
    }()

    func applicationDidFinishLaunching(_: Notification) {
        // TerminalController internally calls ghostty_init(0, nil) exactly once
        // via its own initializeRuntimeIfNeeded() guard, so we do not call
        // Ghostty.initializeRuntime() here to avoid a double-init.

        let tvc = TerminalViewController()
        restoreWorkspace(into: tvc)
        terminalViewController = tvc

        let window = QuerttyWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "quertty"
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.contentMinSize = minimumContentSize
        window.contentViewController = tvc
        window.center()
        window.makeKeyAndOrderFront(nil)
        repairRestoredWindowSizeIfNeeded(window)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        buildMenuBar()
    }

    func applicationWillTerminate(_: Notification) {
        saveWorkspace()
    }

    // MARK: - Persistence helpers

    /// Load the saved workspace and seed the terminal view controller with it.
    ///
    /// Restoration is unconditional — even if `preserveSessions` is false in the
    /// persisted project, we still restore the tab layout.  On any error (missing
    /// file, corrupt JSON) this silently falls back to the default fresh-tab layout
    /// so the app never crashes on bad data.
    private func restoreWorkspace(into tvc: TerminalViewController) {
        do {
            let workspace = try workspaceStore.load()
            let runtimes = SessionSnapshot.projectRuntimes(from: workspace)
            if let model = WorkspaceModel(restoring: runtimes, activeIndex: 0) {
                tvc.restore(workspace: model)
            }
            // Empty runtimes → fall back to the default WorkspaceModel already in tvc.
        } catch {
            // Corrupt or unreadable — start fresh (tvc already has a default model).
        }
    }

    /// Snapshot the current workspace and write it to disk.
    /// Errors are swallowed so a full disk or sandbox denial never crashes the quit path.
    private func saveWorkspace() {
        guard let tvc = terminalViewController else { return }
        let workspace = SessionSnapshot.workspace(from: tvc.currentWorkspace)
        try? workspaceStore.save(workspace)
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    private func repairRestoredWindowSizeIfNeeded(_ window: NSWindow) {
        DispatchQueue.main.async { [defaultContentSize, minimumContentSize] in
            let contentRect = window.contentRect(forFrameRect: window.frame)
            guard contentRect.width < minimumContentSize.width
                || contentRect.height < minimumContentSize.height
            else { return }
            window.setContentSize(defaultContentSize)
            window.center()
        }
    }

    // MARK: - Menu bar

    /// Builds the full menu bar programmatically.
    ///
    /// We bootstrap without a storyboard (see `main.swift`) so AppKit never
    /// loads a `Main.storyboard`; without an explicit menu, the app has no
    /// Quit item or standard shortcuts.  This method creates the minimal set of
    /// menus quertty needs.
    private func buildMenuBar() {
        let mainMenu = NSMenu()

        // ── App menu ──────────────────────────────────────────────────────────
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            NSMenuItem(
                title: "Quit quertty",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )

        // ── Shell menu ────────────────────────────────────────────────────────
        let shellMenuItem = NSMenuItem()
        mainMenu.addItem(shellMenuItem)
        let shellMenu = NSMenu(title: "Shell")
        shellMenuItem.submenu = shellMenu

        // "New Tab"  ⌘T
        let newTab = NSMenuItem(
            title: "New Tab",
            action: #selector(TerminalViewController.newTab(_:)),
            keyEquivalent: "t"
        )
        newTab.keyEquivalentModifierMask = [.command]
        shellMenu.addItem(newTab)

        shellMenu.addItem(.separator())

        // "Split Vertically"  ⌘D
        let splitV = NSMenuItem(
            title: "Split Vertically",
            action: #selector(TerminalViewController.splitVertical(_:)),
            keyEquivalent: "d"
        )
        splitV.keyEquivalentModifierMask = [.command]
        shellMenu.addItem(splitV)

        // "Split Horizontally"  ⇧⌘D
        let splitH = NSMenuItem(
            title: "Split Horizontally",
            action: #selector(TerminalViewController.splitHorizontal(_:)),
            keyEquivalent: "D"
        )
        splitH.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(splitH)

        shellMenu.addItem(.separator())

        // "Close Pane"  ⌘W
        let closePane = NSMenuItem(
            title: "Close Pane",
            action: #selector(TerminalViewController.closePane(_:)),
            keyEquivalent: "w"
        )
        closePane.keyEquivalentModifierMask = [.command]
        shellMenu.addItem(closePane)

        // "Close Tab"  ⇧⌘W
        let closeTab = NSMenuItem(
            title: "Close Tab",
            action: #selector(TerminalViewController.closeTab(_:)),
            keyEquivalent: "W"
        )
        closeTab.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(closeTab)

        shellMenu.addItem(.separator())

        // "Select Next Tab"  ⌘}
        let nextTab = NSMenuItem(
            title: "Select Next Tab",
            action: #selector(TerminalViewController.selectNextTab(_:)),
            keyEquivalent: "}"
        )
        nextTab.keyEquivalentModifierMask = [.command]
        shellMenu.addItem(nextTab)

        // "Select Previous Tab"  ⌘{
        let prevTab = NSMenuItem(
            title: "Select Previous Tab",
            action: #selector(TerminalViewController.selectPreviousTab(_:)),
            keyEquivalent: "{"
        )
        prevTab.keyEquivalentModifierMask = [.command]
        shellMenu.addItem(prevTab)

        // ── Project menu ──────────────────────────────────────────────────────
        let projectMenuItem = NSMenuItem()
        mainMenu.addItem(projectMenuItem)
        let projectMenu = NSMenu(title: "Project")
        projectMenuItem.submenu = projectMenu

        // "Add Project…"  ⌘O
        let addProject = NSMenuItem(
            title: "Add Project\u{2026}",
            action: #selector(TerminalViewController.addProject(_:)),
            keyEquivalent: "o"
        )
        addProject.keyEquivalentModifierMask = [.command]
        projectMenu.addItem(addProject)

        NSApp.mainMenu = mainMenu
    }
}
