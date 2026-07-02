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
    private let defaultContentSize = NSSize(width: 1280, height: 800)
    private let minimumContentSize = NSSize(width: 600, height: 320)
    private var window: NSWindow?

    /// Strong reference to the terminal view controller so it survives until
    /// `applicationWillTerminate` (the window — and thus its contentViewController —
    /// is released on last-window-close, BEFORE terminate; a weak ref would be nil
    /// at save time and the workspace would never persist).
    private var terminalViewController: TerminalViewController?

    /// User config (`~/.config/quertty/config`) and its store.
    private let configStore = ConfigStore()
    private var appConfig = AppConfig()

    /// KVO token for `NSApp.effectiveAppearance`, active only in `system` mode.
    private var appearanceObservation: NSKeyValueObservation?

    /// Watches the config file for external edits (auto-reload).
    private var configWatcher: ConfigFileWatcher?

    /// Installs/removes agent hooks in each harness's config.
    private let hookInstaller = HookInstaller()

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

        // Mark quertty-hosted shells so agent hooks only report sessions running
        // inside quertty (must be set before any pane spawns its shell). Also
        // refresh the installed hook script so the guard reaches existing hooks.
        setenv("QUERTTY", "1", 1)
        hookInstaller.refreshInstalledScriptIfPresent()

        // Load config and resolve the active scheme BEFORE the view controller
        // is created (it reads QTheme.current in viewDidLoad).
        appConfig = configStore.load()
        QTheme.scheme = resolvedScheme()
        NSApp.appearance = appearanceOverride

        let tvc = TerminalViewController()
        restoreWorkspace(into: tvc)
        terminalViewController = tvc
        // Autosave on every structural change (debounced), so the on-disk
        // workspace always reflects the current layout — not just on clean quit.
        tvc.onWorkspaceDidChange = { [weak self] in self?.scheduleSave() }
        tvc.onSelectScheme = { [weak self] scheme in self?.applyScheme(scheme) }
        tvc.onCycleScheme = { [weak self] in self?.cycleColorScheme(nil) }
        tvc.onSetAppearance = { [weak self] mode in self?.setAppearanceMode(mode) }
        tvc.onCycleAppearance = { [weak self] in self?.cycleAppearanceMode() }
        tvc.appearanceModeName = { [weak self] in (self?.appConfig.appearance ?? .system).rawValue.capitalized }
        // Forward the user's ghostty config (file + passthrough) to the terminal.
        tvc.ghosttyConfiguration = makeTerminalConfiguration()
        tvc.onReloadConfig = { [weak self] in self?.reloadConfiguration(nil) }
        // Session preservation must be threaded before the view loads (the
        // launch command is consulted when each pane spawns).
        applySessionPreservation(to: tvc)
        reapOrphanSessions(tvc)
        startControlSocket()

        let window = QuerttyWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "quertty"
        window.isOpaque = true
        window.appearance = appearanceOverride
        window.backgroundColor = QTheme.current.bg1Color
        window.titlebarAppearsTransparent = true
        window.contentMinSize = minimumContentSize
        window.contentViewController = tvc
        // Persist and restore the window frame across launches. On first launch
        // (no saved frame) fall back to centering the default size.
        window.setFrameAutosaveName("QuerttyMainWindow")
        if !window.setFrameUsingName("QuerttyMainWindow") {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        repairRestoredWindowSizeIfNeeded(window)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        startObservingSystemAppearance()
        buildMenuBar()

        // Auto-reload when the config file changes on disk.
        let watcher = ConfigFileWatcher(url: configStore.fileURL) { [weak self] in
            self?.reloadConfiguration(nil)
        }
        watcher.start()
        configWatcher = watcher
    }

    /// Persists the config, suppressing the watcher's self-write bounce.
    private func saveConfig() {
        configStore.save(appConfig)
        configWatcher?.markSaved()
    }

    // MARK: - Appearance

    /// Whether the OS is currently in dark mode (only meaningful in system mode,
    /// where `NSApp.appearance` is left unset so it tracks the OS).
    private var osIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The concrete scheme for the current config + OS appearance.
    private func resolvedScheme() -> QColorScheme {
        switch appConfig.appearance {
        case .dark:
            return QColorScheme.named(appConfig.themeDark) ?? .midnight
        case .light:
            return QColorScheme.named(appConfig.themeLight) ?? .paper
        case .system:
            let name = osIsDark ? appConfig.themeDark : appConfig.themeLight
            return QColorScheme.named(name) ?? (osIsDark ? .midnight : .paper)
        }
    }

    /// The app/window appearance to pin. `nil` in system mode so
    /// `NSApp.effectiveAppearance` keeps tracking the OS (and our KVO keeps firing);
    /// the resolved scheme's appearance in the explicit dark/light modes.
    private var appearanceOverride: NSAppearance? {
        appConfig.appearance == .system ? nil : QTheme.current.appearance
    }

    /// In system mode, watch for OS appearance toggles and re-theme live.
    private func startObservingSystemAppearance() {
        appearanceObservation = nil
        guard appConfig.appearance == .system else { return }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.systemAppearanceDidChange() }
        }
    }

    private func systemAppearanceDidChange() {
        let newScheme = resolvedScheme()
        guard newScheme != QTheme.scheme else { return }
        QTheme.scheme = newScheme
        window?.backgroundColor = QTheme.current.bg1Color
        terminalViewController?.applyTheme()
    }

    /// Cycles to the next scheme WITHIN the current dark/light axis (⇧⌘T), so it
    /// never crosses the light↔dark boundary. Applies + persists.
    @objc func cycleColorScheme(_ sender: Any?) {
        let scoped = QTheme.current.isDark ? QColorScheme.darkSchemes : QColorScheme.lightSchemes
        guard !scoped.isEmpty else { return }
        let index = scoped.firstIndex(of: QTheme.scheme) ?? -1
        applyScheme(scoped[(index + 1) % scoped.count])
    }

    /// Applies `scheme` live (chrome + terminals) and persists it to the config
    /// as the dark or light choice (matching the scheme's own darkness).
    ///
    /// Does NOT touch the appearance axis: schemes only change within the current
    /// axis, so the existing app appearance already matches.
    func applyScheme(_ scheme: QColorScheme) {
        QTheme.scheme = scheme
        window?.backgroundColor = QTheme.current.bg1Color
        terminalViewController?.applyTheme()

        if scheme.isDark {
            appConfig.themeDark = scheme.displayName
        } else {
            appConfig.themeLight = scheme.displayName
        }
        saveConfig()
    }

    /// Persists `scheme` as the dark or light choice, applying it live only
    /// when it belongs to the currently visible axis — picking the other
    /// axis's theme (e.g. the light theme while in dark mode) shouldn't flip
    /// the window; it takes effect next time that axis is active.
    func selectTheme(_ scheme: QColorScheme) {
        if scheme.isDark == QTheme.scheme.isDark {
            applyScheme(scheme)   // applies live + persists
            return
        }
        if scheme.isDark {
            appConfig.themeDark = scheme.displayName
        } else {
            appConfig.themeLight = scheme.displayName
        }
        saveConfig()
    }

    /// Switches the appearance axis (system / dark / light), re-resolving the
    /// scheme, updating chrome + observation, and persisting.
    func setAppearanceMode(_ mode: AppearanceMode) {
        appConfig.appearance = mode
        QTheme.scheme = resolvedScheme()
        NSApp.appearance = appearanceOverride
        window?.appearance = appearanceOverride
        window?.backgroundColor = QTheme.current.bg1Color
        terminalViewController?.applyTheme()
        startObservingSystemAppearance()   // (re)arm or disarm the OS-follow KVO
        saveConfig()
    }

    @objc private func setAppearanceSystem(_ sender: Any?) { setAppearanceMode(.system) }
    @objc private func setAppearanceDark(_ sender: Any?) { setAppearanceMode(.dark) }
    @objc private func setAppearanceLight(_ sender: Any?) { setAppearanceMode(.light) }

    /// Ghostty directives quertty ships as defaults. The user's own config
    /// directives are applied after these, so they win on conflict (ghostty
    /// last-wins semantics for scalar keys).
    private static let defaultGhosttyDirectives: [(key: String, value: String)] = [
        ("shell-integration", "zsh"),
        ("shell-integration-features", "ssh-env,ssh-terminfo"),
    ]

    /// Builds the terminal config: quertty's default directives, then the
    /// ghostty directives pasted into quertty's config.
    private func makeTerminalConfiguration() -> TerminalConfiguration? {
        TerminalConfiguration { builder in
            for directive in Self.defaultGhosttyDirectives {
                builder.withCustom(directive.key, directive.value)
            }
            for directive in appConfig.ghostty {
                builder.withCustom(directive.key, directive.value)
            }
        }
    }

    /// Reloads all config from disk (⇧⌘,, like ghostty): re-reads quertty's
    /// config + the ghostty file, re-resolves appearance/scheme, and re-applies
    /// the theme + terminal overrides to every live pane — no relaunch needed.
    @objc func reloadConfiguration(_ sender: Any?) {
        appConfig = configStore.load()
        QTheme.scheme = resolvedScheme()
        NSApp.appearance = appearanceOverride
        window?.appearance = appearanceOverride
        window?.backgroundColor = QTheme.current.bg1Color
        startObservingSystemAppearance()
        terminalViewController?.applyTheme()                                  // chrome + terminal theme
        terminalViewController?.reloadGhosttyConfiguration(makeTerminalConfiguration())  // terminal overrides
        if let tvc = terminalViewController {
            applySessionPreservation(to: tvc)                                 // affects new panes only
        }
    }

    // MARK: - Session preservation

    /// Threads session preservation into the terminal VC: when enabled and zmx
    /// is installed, new panes launch `zmx attach quertty-<id>` instead of a
    /// bare shell. Affects NEW panes only. Explicitly closed panes always get
    /// their sessions killed when zmx is present (regardless of the toggle, so
    /// closing panes after disabling still cleans up).
    private func applySessionPreservation(to tvc: TerminalViewController) {
        let zmxPath = ZmxRunner.locate()

        if appConfig.preserveSessions, let zmx = zmxPath {
            tvc.sessionCommandProvider = { id in
                SessionPersistence.attachCommand(zmxPath: zmx, surfaceID: id)
            }
        } else {
            tvc.sessionCommandProvider = nil
            if appConfig.preserveSessions { presentZmxMissingAlertOnce() }
        }

        if let zmx = zmxPath {
            tvc.onSurfacesClosed = { ids in
                ZmxRunner.kill(sessions: ids.map(SessionPersistence.sessionName(for:)), zmxPath: zmx)
            }
        } else {
            tvc.onSurfacesClosed = nil
        }
    }

    /// One-shot startup reap: kills quertty zmx sessions that no restored
    /// surface owns. Clean quits kill sessions on explicit close, so orphans
    /// only appear after crashes or workspace-file loss; without this they
    /// would accumulate silently (Settings also offers a manual kill).
    private func reapOrphanSessions(_ tvc: TerminalViewController) {
        guard let zmx = ZmxRunner.locate() else { return }
        let liveIDs = tvc.allSurfaceIDs
        DispatchQueue.global(qos: .utility).async {
            let existing = ZmxRunner.listQuerttySessions(zmxPath: zmx)
            let orphans = SessionPersistence.orphans(existing: existing, liveSurfaceIDs: liveIDs)
            ZmxRunner.kill(sessions: orphans, zmxPath: zmx)
        }
    }

    /// One-time guidance when `preserve-sessions = true` was set by hand but
    /// zmx isn't installed (the Settings toggle drives an install instead).
    private func presentZmxMissingAlertOnce() {
        let key = "quertty.zmxMissingAlertShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "preserve-sessions is on, but zmx is not installed"
            alert.informativeText = """
            Panes will use plain shells until zmx is installed.

            \(ZmxRunner.installHint)

            Settings (⌘,) can install it for you.
            """
            alert.runModal()
        }
    }

    // MARK: - Settings

    private var settingsWindowController: SettingsWindowController?

    @objc private func openSettings(_ sender: Any?) {
        let controller = settingsWindowController ?? SettingsWindowController(
            installer: hookInstaller,
            liveSurfaceIDs: { [weak self] in self?.terminalViewController?.allSurfaceIDs ?? [] }
        )
        controller.onSetAppearance = { [weak self] mode in self?.setAppearanceMode(mode) }
        controller.onSelectTheme = { [weak self] scheme in self?.selectTheme(scheme) }
        settingsWindowController = controller
        controller.refresh()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func cycleAppearance(_ sender: Any?) { cycleAppearanceMode() }

    /// Cycles the appearance axis System → Dark → Light → System.
    func cycleAppearanceMode() {
        let order: [AppearanceMode] = [.system, .dark, .light]
        let index = order.firstIndex(of: appConfig.appearance) ?? 0
        setAppearanceMode(order[(index + 1) % order.count])
    }

    /// Set by a CLI `quit` (explicit intent — no dialog on top of it).
    private var skipQuitConfirmation = false

    /// Quit confirmation (config `confirm-quit`, Settings toggle). The message
    /// reflects what quitting actually does: preserved sessions keep running,
    /// plain shells are terminated.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard appConfig.confirmQuit, !skipQuitConfirmation else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit quertty?"
        alert.informativeText = appConfig.preserveSessions
            ? "Preserved sessions keep running and reattach on next launch."
            : "Running processes in panes will be terminated."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_: Notification) {
        controlSocketServer?.stop()
        saveWorkspace()
    }

    // MARK: - Control socket (quertty CLI)

    private var controlSocketServer: ControlSocketServer?

    /// Hosts `~/.quertty/quertty.sock` for the `quertty` CLI: status snapshot,
    /// input injection (`send`), and config reload.
    private func startControlSocket() {
        let server = ControlSocketServer { [weak self] request in
            guard let self, let tvc = self.terminalViewController else {
                return .error("quertty is still starting up")
            }
            switch request {
            case .status:
                return .status(tvc.statusSnapshot())
            case .reload:
                self.reloadConfiguration(nil)
                return .ok
            case .send(let target, let text, let enter, let keys):
                if let message = tvc.sendInput(target: target, text: text, enter: enter, keys: keys) {
                    return .error(message)
                }
                return .ok
            case .newTab(let project):
                switch tvc.openNewTab(inProject: project) {
                case .success(let pane): return .pane(pane)
                case .failure(let error): return .error(error.localizedDescription)
                }
            case .close(let target, let wholeTab):
                if let message = tvc.closePane(target: target, wholeTab: wholeTab) {
                    return .error(message)
                }
                return .ok
            case .quit(let killSessions):
                // Respond first, then terminate on the next runloop turn.
                self.skipQuitConfirmation = true
                DispatchQueue.main.async {
                    if killSessions, let zmx = ZmxRunner.locate() {
                        let sessions = ZmxRunner.listQuerttySessions(zmxPath: zmx)
                        ZmxRunner.killAndWait(sessions: sessions, zmxPath: zmx)
                    }
                    NSApp.terminate(nil)
                }
                return .ok
            case .split(let target, let vertical):
                switch tvc.splitPane(target: target, vertical: vertical) {
                case .success(let pane): return .pane(pane)
                case .failure(let error): return .error(error.localizedDescription)
                }
            case .focus(let target):
                if let message = tvc.focusPane(target: target) {
                    return .error(message)
                }
                return .ok
            case .capture(let target, let lines):
                switch tvc.capturePane(target: target, lines: lines) {
                case .success(let text): return .text(text)
                case .failure(let error): return .error(error.localizedDescription)
                }
            }
        }
        server.start()
        controlSocketServer = server
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

    /// Pending debounced autosave (coalesces rapid structural changes into one write).
    private var pendingSave: DispatchWorkItem?

    /// Schedule a debounced autosave. Multiple changes within the window collapse
    /// to a single disk write.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveWorkspace() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Snapshot the current workspace and write it to disk.
    /// Errors are swallowed so a full disk or sandbox denial never crashes the quit path.
    private func saveWorkspace() {
        pendingSave?.cancel()
        pendingSave = nil
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
        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        let reloadConfig = NSMenuItem(
            title: "Reload Configuration",
            action: #selector(reloadConfiguration(_:)),
            keyEquivalent: ","
        )
        reloadConfig.keyEquivalentModifierMask = [.command, .shift]
        reloadConfig.target = self
        appMenu.addItem(reloadConfig)
        appMenu.addItem(.separator())
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

        // ── View menu ─────────────────────────────────────────────────────────
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        // "Command Palette…"  ⌘K
        let palette = NSMenuItem(
            title: "Command Palette\u{2026}",
            action: #selector(TerminalViewController.toggleCommandPalette(_:)),
            keyEquivalent: "k"
        )
        palette.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(palette)

        // "Toggle Sidebar"  ⌘B
        let toggleSidebar = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(TerminalViewController.toggleSidebar(_:)),
            keyEquivalent: "b"
        )
        toggleSidebar.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(toggleSidebar)

        // "Cycle Color Scheme"  ⇧⌘T — targets the app delegate (owns the config).
        let cycleScheme = NSMenuItem(
            title: "Cycle Color Scheme",
            action: #selector(cycleColorScheme(_:)),
            keyEquivalent: "T"
        )
        cycleScheme.keyEquivalentModifierMask = [.command, .shift]
        cycleScheme.target = self
        viewMenu.addItem(cycleScheme)

        // "Cycle Appearance"  ⇧⌘A
        let cycleAppearanceItem = NSMenuItem(
            title: "Cycle Appearance",
            action: #selector(cycleAppearance(_:)),
            keyEquivalent: "A"
        )
        cycleAppearanceItem.keyEquivalentModifierMask = [.command, .shift]
        cycleAppearanceItem.target = self
        viewMenu.addItem(cycleAppearanceItem)

        // "Appearance" submenu — the dark/light/system axis.
        let appearanceItem = NSMenuItem()
        appearanceItem.title = "Appearance"
        let appearanceMenu = NSMenu(title: "Appearance")
        appearanceItem.submenu = appearanceMenu
        for (title, action) in [
            ("System", #selector(setAppearanceSystem(_:))),
            ("Dark", #selector(setAppearanceDark(_:))),
            ("Light", #selector(setAppearanceLight(_:))),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            appearanceMenu.addItem(entry)
        }
        viewMenu.addItem(appearanceItem)

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

        // Target the view-controller actions DIRECTLY at the (retained) TVC rather
        // than relying on the responder chain. Responder-chain routing only reaches
        // the TVC when a terminal pane holds first responder, so ⌘W/⇧⌘W etc. would
        // silently no-op whenever focus wasn't on a pane. An explicit target always fires.
        // Route menu actions directly at the (retained) TVC, except items that
        // already have an explicit target (e.g. the scheme cycler → app delegate).
        for item in shellMenu.items + projectMenu.items + viewMenu.items
        where item.action != nil && item.target == nil {
            item.target = terminalViewController
        }

        NSApp.mainMenu = mainMenu
    }
}
