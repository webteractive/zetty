import AppKit
import ZettyGhostty
import UserNotifications

/// Window that gives the app's main-menu key equivalents (⌘D / ⇧⌘D / ⌘W)
/// priority over the focused view. The embedded GhosttyTerminal view otherwise
/// consumes those key equivalents (AppKit hands the view hierarchy first crack),
/// so menu shortcuts never fire. Checking the main menu before `super` (which
/// forwards to the view hierarchy) restores the expected app-shortcut behaviour.
final class ZettyWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class StatusMenuDestination: NSObject {
    let projectID: UUID
    let tabIndex: Int?

    init(projectID: UUID, tabIndex: Int?) {
        self.projectID = projectID
        self.tabIndex = tabIndex
    }
}

// NOTE: no `@main` here. Tuist's default macOS Info.plist sets
// NSMainStoryboardFile = "Main", and `@main` on an NSApplicationDelegate routes
// through NSApplicationMain, which eagerly loads that (nonexistent) storyboard
// and crashes before the delegate runs. We bootstrap NSApplication manually in
// main.swift instead, which never consults the storyboard key.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let defaultContentSize = NSSize(width: 1280, height: 800)
    private let minimumContentSize = NSSize(width: 600, height: 320)
    private var window: NSWindow?
    /// Exists only while the retained main window is hidden.
    private var statusItem: NSStatusItem?

    /// Strong reference to the terminal view controller so it survives until
    /// `applicationWillTerminate` (the window — and thus its contentViewController —
    /// is released on last-window-close, BEFORE terminate; a weak ref would be nil
    /// at save time and the workspace would never persist).
    private var terminalViewController: TerminalViewController?

    // MARK: - ssh:// URL handover
    //
    // Another app opens ssh://user@host; macOS delivers it here (Zetty is
    // registered for the scheme in Project.swift). URLs that arrive before the
    // workspace is restored on cold launch wait in `pendingSSHURLs`.
    private var pendingSSHURLs: [URL] = []
    private var workspaceReady = false

    private lazy var updateChecker = UpdateChecker(
        currentVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
    private let updateInstaller = UpdateInstaller()
    private var updateProgressAlert: NSAlert?
    private var updateTimer: Timer?

    /// User config (`~/.config/zetty/config`) and its store.
    private let configStore = ConfigStore()
    private var appConfig = AppConfig()

    /// KVO token for `NSApp.effectiveAppearance`, active only in `system` mode.
    private var appearanceObservation: NSKeyValueObservation?

    /// Routes SIGTERM (killall, logout) through the normal terminate path so
    /// the workspace save + socket cleanup run instead of dying mid-debounce.
    private var sigtermSource: DispatchSourceSignal?

    /// Watches the config file for external edits (auto-reload).
    private var configWatcher: ConfigFileWatcher?

    /// Installs/removes agent hooks in each harness's config.
    private let hookInstaller = HookInstaller()

    /// `~/Library/Application Support/zetty/` (created on first use) — shared
    /// by the workspace and project-settings stores.
    private lazy var appSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("zetty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The persistent workspace store backed by `~/Library/Application Support/zetty/`.
    private lazy var workspaceStore = WorkspaceStore(directory: appSupportDirectory)

    /// Private per-project settings (identity + overrides), keyed by rootPath.
    private lazy var projectSettingsStore = ProjectSettingsStore(directory: appSupportDirectory)

    /// Global default layout template (hand-editable; a project's repo file
    /// wins when it carries its own).
    private lazy var layoutTemplateStore = LayoutTemplateStore(directory: appSupportDirectory)

    /// In-memory project settings; loaded at launch, saved on every edit.
    private(set) var projectSettings = ProjectSettingsFile()

    func applicationDidFinishLaunching(_: Notification) {
        // TerminalController internally calls ghostty_init(0, nil) exactly once
        // via its own initializeRuntimeIfNeeded() guard, so we do not call
        // Ghostty.initializeRuntime() here to avoid a double-init.

        // Mark Zetty-hosted shells so agent hooks only report sessions running
        // inside Zetty (must be set before any pane spawns its shell). Also
        // refresh the installed hook script so the guard reaches existing hooks.
        setenv("ZETTY", "1", 1)
        hookInstaller.refreshInstalledScriptIfPresent()

        // Graceful SIGTERM: save the workspace and tear down via the normal
        // terminate path (no confirmation — the signal IS the intent). Without
        // this, killall drops any structural change still in the 0.4s autosave
        // debounce window. A no-op handler (NOT SIG_IGN) keeps default delivery
        // from killing us before the source fires — SIG_IGN would survive exec
        // and make every pane's shell tree immune to SIGTERM.
        signal(SIGTERM) { _ in }
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { NSApp.terminate(nil) }
        sigterm.resume()
        sigtermSource = sigterm

        // Load config and resolve the active scheme BEFORE the view controller
        // is created (it reads ZTheme.current in viewDidLoad).
        appConfig = configStore.load()
        ZTheme.scheme = resolvedScheme()
        applyChromeFontFromConfig()             // chrome font before any view reads monoFont
        NSApp.appearance = appearanceOverride
        ZTheme.registerBundledFonts()           // JetBrains Mono default ships with the app

        let tvc = TerminalViewController()
        tvc.sidebarPosition = appConfig.sidebarPosition
        let restoredFromDisk = restoreWorkspace(into: tvc)
        terminalViewController = tvc
        projectSettings = projectSettingsStore.load()
        applyProjectNameOverrides(to: tvc)
        applyThemeForActiveProject()   // initial active project's theme override
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
        tvc.onOpenSettings = { [weak self] in self?.openSettings(nil) }
        // A rejected terminal config used to be silent — and since rejection
        // drops the session-preservation `command`, it stranded preserved
        // sessions on every relaunch. Surface it once per run instead.
        tvc.onGhosttyConfigurationRejected = { [weak self] issue in
            self?.presentGhosttyConfigRejectedAlertOnce(issue: issue)
        }
        // Session preservation must be threaded before the view loads (the
        // launch command is consulted when each pane spawns).
        applySessionPreservation(to: tvc)
        // Reap only against a successfully restored layout — after a fallback
        // every preserved session would look like an orphan and be killed.
        if restoredFromDisk { reapOrphanSessions(tvc) }
        startControlSocket()

        // Agent needs-attention notifications (two levels, config-gated).
        UNUserNotificationCenter.current().delegate = self
        tvc.onAgentNeedsAttention = { [weak self] surface, kind, project in
            self?.agentNeedsAttention(surface: surface, kind: kind, project: project)
        }
        tvc.badgeEligible = { [weak self] project in
            self?.resolvedSettings(for: project).notifyBadge ?? true
        }
        tvc.projectIdentity = { [weak self] project in
            guard let self else { return (nil, nil) }
            let resolved = self.resolvedSettings(for: project)
            return (ZTheme.projectColor(id: resolved.colorID), resolved.icon)
        }
        tvc.agentsProvider = { [weak self] project in
            guard let self else { return .disabled }
            let settings = self.projectSettings.settings(for: project.settingsKey)
            return SpawnableAgent.spawnConfig(
                agents: settings?.agents,
                promptOnNewPane: settings?.promptAgentOnNewPane != false)
        }
        tvc.onRenameProject = { [weak self] project in self?.promptRenameProject(project) }
        tvc.onOpenProjectSettings = { [weak self] project in self?.presentProjectSettings(project) }
        tvc.onOpenAgentSettings = { [weak self] project in self?.presentProjectSettings(project, initialTab: "agents") }
        tvc.onUpdatePillClicked = { [weak self] in self?.versionPillClicked() }
        tvc.onCLIReinstallClicked = { [weak self] in
            CLILink.install()
            self?.refreshCLIStatus()
        }
        tvc.autoHibernateAfter = { [weak self] in self?.appConfig.hibernateAfter ?? 0 }
        tvc.autoHibernateDisabled = { [weak self] project in
            self?.projectSettings.settings(for: project.settingsKey)?.autoHibernate == false
        }
        tvc.broadcastScopeProvider = { [weak self] project in
            BroadcastScope(code: self?.projectSettings.settings(for: project.settingsKey)?.broadcastScope)
        }
        tvc.onSetBroadcastScope = { [weak self] project, scope in
            self?.setBroadcastScope(scope, for: project)
        }
        tvc.onActiveProjectChanged = { [weak self] in self?.applyThemeForActiveProject() }
        tvc.viewerSettingsProvider = { [weak self] in
            let config = self?.appConfig ?? AppConfig()
            return (config.viewerHighlightCommand, config.viewerMaxBytes)
        }
        tvc.fileTreeSettingsProvider = { [weak self] in
            self?.appConfig.fileTree ?? FileTreeSettings()
        }
        tvc.editorProvider = { [weak self] in self?.appConfig.editor }
        tvc.layoutTemplateProvider = { [weak self] project in
            ProjectFileIO.load(projectRoot: project.rootPath)?.layoutTemplate
                ?? self?.layoutTemplateStore.load()
        }
        tvc.surfaceEnvironmentProvider = { [weak self, weak tvc] id in
            var env: [String: String] = [:]
            if let self, let project = tvc?.workspace.project(containing: id) {
                env = self.resolvedSettings(for: project).env
            }
            // The bundled zsh integration writes $PWD here on every cd so the
            // status bar can show the focused pane's live working directory.
            env["ZETTY_CWD_FILE"] = PaneCwdStore.path(for: id)
            return env
        }
        tvc.onAttentionCountChanged = { [weak self] count in
            guard let self else { return }
            NSApp.dockTile.badgeLabel = (self.appConfig.notifyBadge && count > 0) ? "\(count)" : nil
        }
        // Reading an attention item in-app also sweeps its Notification
        // Center banners, so visited alerts don't linger there.
        tvc.onAttentionRead = { surfaceID in
            let shortID = SessionPersistence.shortID(for: surfaceID)
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { delivered in
                let ids = delivered
                    .filter { ($0.request.content.userInfo["pane"] as? String) == shortID }
                    .map(\.request.identifier)
                if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
            }
        }
        tvc.onAttentionReadAll = {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }

        let window = ZettyWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Zetty"
        window.isOpaque = true
        window.appearance = appearanceOverride
        window.backgroundColor = ZTheme.current.bg1Color
        window.titlebarAppearsTransparent = true
        window.contentMinSize = minimumContentSize
        window.contentViewController = tvc
        window.delegate = self   // red x hands the retained window to the status item
        // We hold a strong reference in self.window; the AppKit default (true)
        // would over-release the window if it ever closes while the app lives.
        window.isReleasedWhenClosed = false
        // Persist and restore the window frame across launches. On first launch
        // (no saved frame) fall back to centering the default size.
        window.setFrameAutosaveName("ZettyMainWindow")
        if !window.setFrameUsingName("ZettyMainWindow") {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        repairRestoredWindowSizeIfNeeded(window)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        // tmux-style prefix-key layer (Ctrl+B by default; prefix/bind/copy-bind
        // config lines remap it). Installed after the window exists so the
        // interceptor's window guard has something to compare against.
        tvc.installKeyBindings(appConfig.keybindings)

        startObservingSystemAppearance()
        buildMenuBar()

        // Auto-reload when the config file changes on disk.
        let watcher = ConfigFileWatcher(url: configStore.fileURL) { [weak self] in
            self?.reloadConfiguration(nil)
        }
        watcher.start()
        configWatcher = watcher

        startUpdateChecks()
        refreshCLIStatus()
        tvc.startHibernationTimer()

        // The workspace is fully restored and the window is up — any ssh:// URL
        // that cold-launched us (queued in application(_:open:)) can now open.
        workspaceReady = true
        drainPendingSSHURLs()
    }

    /// Reflects the CLI symlink's staleness in the status bar (pill when it
    /// points at an old build or is missing).
    private func refreshCLIStatus() {
        terminalViewController?.showCLIStatus(CLILink.status())
    }

    func applicationDidBecomeActive(_: Notification) {
        // Re-check on focus so moving/replacing the app (which staleifies the
        // symlink) is reflected without a relaunch.
        refreshCLIStatus()
    }

    // MARK: - ssh:// URL handover

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "ssh" {
            if workspaceReady {
                handleSSHURL(url)
            } else {
                pendingSSHURLs.append(url)
            }
        }
    }

    /// Validates one ssh:// URL and, if safe, opens it in a Home tab and brings
    /// Zetty to the front. Invalid/unsafe URLs are ignored (with a beep).
    private func handleSSHURL(_ url: URL) {
        guard let command = SSHURLHandler.command(for: url) else {
            NSSound.beep()
            return
        }
        terminalViewController?.openSSHSession(command: command)
        showMainWindow()
    }

    /// Drains ssh:// URLs that arrived before the workspace was ready.
    private func drainPendingSSHURLs() {
        let urls = pendingSSHURLs
        pendingSSHURLs.removeAll()
        urls.forEach(handleSSHURL)
    }

    // MARK: - Update checks

    /// Auto-check on launch + a periodic timer, gated by config + a 6h throttle.
    private func startUpdateChecks() {
        guard appConfig.checkUpdates else { return }
        runUpdateCheckIfDue()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.runUpdateCheckIfDue()
        }
    }

    private func runUpdateCheckIfDue() {
        guard appConfig.checkUpdates else { return }
        let key = "Zetty.lastUpdateCheck"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard now - last >= 6 * 3600 else { return }
        UserDefaults.standard.set(now, forKey: key)
        updateChecker.check { [weak self] result in
            if case .success(let update) = result { self?.terminalViewController?.showUpdate(update) }
        }
    }

    /// Version-pill click: check now, reflect the result in the pill, then
    /// offer to install a newer version (or report up-to-date).
    private func versionPillClicked() {
        checkThenOfferUpdate()
    }

    /// Manual "Check for Updates…" — always runs, reports the outcome.
    @objc private func checkForUpdates(_ sender: Any?) {
        checkThenOfferUpdate()
    }

    private func checkThenOfferUpdate() {
        updateChecker.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let update):
                self.terminalViewController?.showUpdate(update)
                if let update { self.presentUpdate(update) }
                else { self.showUpdateInfo("You're up to date.") }
            case .failure:
                self.showUpdateInfo("Couldn't check for updates.")
            }
        }
    }

    /// Confirm dialog for a newer version, then download+install in place.
    /// Falls back to the release page when the release isn't installable.
    private func presentUpdate(_ update: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = "Update to \(update.version)?"
        if update.isInstallable {
            alert.informativeText = "Zetty will download the update and restart."
            alert.addButton(withTitle: "Install & Restart")
            alert.addButton(withTitle: "View Release Notes")
            alert.addButton(withTitle: "Later")
        } else {
            alert.informativeText = "A newer version is available on the releases page."
            alert.addButton(withTitle: "View Release Notes")
            alert.addButton(withTitle: "Later")
        }
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if update.isInstallable {
                switch response {
                case .alertFirstButtonReturn: self.startInstall(update)
                case .alertSecondButtonReturn: NSWorkspace.shared.open(update.releasePage)
                default: break
                }
            } else if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(update.releasePage)
            }
        }
        if let window = terminalViewController?.view.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// Runs the installer behind a modeless progress sheet. On success the
    /// installer terminates the app into the swap helper; on failure the
    /// current app is untouched and we surface the reason.
    private func startInstall(_ update: AvailableUpdate) {
        let progress = NSAlert()
        progress.messageText = "Updating to \(update.version)…"
        progress.informativeText = "Downloading…"
        let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 16))
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        progress.accessoryView = bar
        updateProgressAlert = progress

        let onProgress: (UpdateInstallProgress) -> Void = { [weak progress, weak bar] p in
            switch p {
            case .downloading(let f): bar?.doubleValue = f; progress?.informativeText = "Downloading…"
            case .verifying: bar?.isIndeterminate = true; bar?.startAnimation(nil); progress?.informativeText = "Verifying…"
            case .preparing: progress?.informativeText = "Preparing…"
            case .relaunching: progress?.informativeText = "Restarting…"
            }
        }
        let onDone: (Result<Void, UpdateInstallError>) -> Void = { [weak self] result in
            guard let self else { return }
            if let window = self.terminalViewController?.view.window,
               let sheet = self.updateProgressAlert?.window {
                window.endSheet(sheet)
            }
            self.updateProgressAlert = nil
            if case .failure(let error) = result {
                self.showUpdateInfo(String(describing: error))
            }
            // .success terminates the app from the installer.
        }

        if let window = terminalViewController?.view.window {
            progress.beginSheetModal(for: window) { _ in }
        }
        updateInstaller.install(update, progress: onProgress, completion: onDone)
    }

    private func showUpdateInfo(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        if let window = terminalViewController?.view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// Persists the config, suppressing the watcher's self-write bounce.
    private func saveConfig() {
        configStore.save(appConfig)
        configWatcher?.markSaved()
    }

    // MARK: - Appearance

    /// Whether the OS is currently in dark mode — pin-free: while
    /// `NSApp.appearance` is pinned (explicit global mode, or a per-project
    /// appearance override), `effectiveAppearance` follows the pin and would
    /// lie about the OS, so read the system default instead.
    private var osIsDark: Bool {
        if NSApp.appearance == nil {
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// The concrete scheme for the current config + OS appearance.
    private func resolvedScheme() -> ZColorScheme {
        switch appConfig.appearance {
        case .dark:
            return ZColorScheme.named(appConfig.themeDark) ?? .midnight
        case .light:
            return ZColorScheme.named(appConfig.themeLight) ?? .paper
        case .system:
            let name = osIsDark ? appConfig.themeDark : appConfig.themeLight
            return ZColorScheme.named(name) ?? (osIsDark ? .midnight : .paper)
        }
    }

    /// The app/window appearance to pin. `nil` in system mode so
    /// `NSApp.effectiveAppearance` keeps tracking the OS (and our KVO keeps firing);
    /// the resolved scheme's appearance in the explicit dark/light modes.
    private var appearanceOverride: NSAppearance? {
        appConfig.appearance == .system ? nil : ZTheme.current.appearance
    }

    /// OS appearance-change observer (distributed notification). Fires on
    /// the system toggle even while `NSApp.appearance` is pinned — the KVO
    /// on `effectiveAppearance` goes silent under a pin, and a per-project
    /// appearance override can make the EFFECTIVE mode system while the
    /// global is pinned. The decision point no-ops when the flip doesn't
    /// matter.
    private var interfaceThemeObserver: NSObjectProtocol?

    private func startObservingSystemAppearance() {
        appearanceObservation = nil
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.systemAppearanceDidChange() }
        }
        guard interfaceThemeObserver == nil else { return }
        interfaceThemeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemAppearanceDidChange()
        }
    }

    private func systemAppearanceDidChange() {
        applyThemeForActiveProject()
    }

    /// Applies `scheme` to chrome + terminals WITHOUT persisting — the
    /// visual half of `applyScheme`, also used for per-project overrides
    /// (which must never write into the global config).
    private func applySchemeTransient(_ scheme: ZColorScheme) {
        guard scheme != ZTheme.scheme else { return }
        ZTheme.scheme = scheme
        window?.backgroundColor = ZTheme.current.bg1Color
        terminalViewController?.applyTheme()
    }

    /// The single visual theme decision point, modeled exactly on the global
    /// resolution (appearance axis → scheme per axis) with the active
    /// project's overrides folded in per field: effective appearance =
    /// project override ?? global; effective scheme = the project's
    /// theme-dark/-light override for that axis ?? the global one. Unknown
    /// scheme names fall back to the global choice. Called on project
    /// activation, OS appearance flips, config reloads, and settings edits.
    func applyThemeForActiveProject() {
        var appearance = appConfig.appearance
        var themeDark = appConfig.themeDark
        var themeLight = appConfig.themeLight
        if let tvc = terminalViewController {
            let resolved = resolvedSettings(for: tvc.workspace.activeProject)
            if let mode = resolved.appearanceOverride.flatMap(AppearanceMode.init(rawValue:)) {
                appearance = mode
            }
            if let dark = resolved.themeDarkOverride, ZColorScheme.named(dark) != nil {
                themeDark = dark
            }
            if let light = resolved.themeLightOverride, ZColorScheme.named(light) != nil {
                themeLight = light
            }
        }

        let isDark: Bool
        switch appearance {
        case .dark: isDark = true
        case .light: isDark = false
        case .system: isDark = osIsDark
        }
        let scheme = ZColorScheme.named(isDark ? themeDark : themeLight)
            ?? (isDark ? .midnight : .paper)
        applySchemeTransient(scheme)
        // Pin (or release) the app/window appearance for the EFFECTIVE axis,
        // like the global appearanceOverride does — a project pinned dark
        // under a light system needs dark chrome for menus/sheets too.
        let pin: NSAppearance? = appearance == .system ? nil : ZTheme.current.appearance
        NSApp.appearance = pin
        window?.appearance = pin
    }

    /// Cycles to the next scheme WITHIN the current dark/light axis (⇧⌘T), so it
    /// never crosses the light↔dark boundary. Applies + persists.
    @objc func cycleColorScheme(_ sender: Any?) {
        let scoped = ZTheme.current.isDark ? ZColorScheme.darkSchemes : ZColorScheme.lightSchemes
        guard !scoped.isEmpty else { return }
        let index = scoped.firstIndex(of: ZTheme.scheme) ?? -1
        applyScheme(scoped[(index + 1) % scoped.count])
    }

    /// Applies `scheme` live (chrome + terminals) and persists it to the config
    /// as the dark or light choice (matching the scheme's own darkness).
    ///
    /// Does NOT touch the appearance axis: schemes only change within the current
    /// axis, so the existing app appearance already matches.
    func applyScheme(_ scheme: ZColorScheme) {
        if scheme.isDark {
            appConfig.themeDark = scheme.displayName
        } else {
            appConfig.themeLight = scheme.displayName
        }
        saveConfig()
        // Visuals route through the per-project decision point: while the
        // active project has a theme override it keeps winning (the new
        // global shows on projects without one); otherwise the newly
        // persisted global applies immediately.
        applyThemeForActiveProject()
    }

    /// Persists `scheme` as the dark or light choice, applying it live only
    /// when it belongs to the currently visible axis — picking the other
    /// axis's theme (e.g. the light theme while in dark mode) shouldn't flip
    /// the window; it takes effect next time that axis is active.
    func selectTheme(_ scheme: ZColorScheme) {
        if scheme.isDark == ZTheme.scheme.isDark {
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
        // Visuals + appearance pinning route through the per-project decision
        // point, so an active project's appearance/theme overrides keep
        // winning over the new global.
        applyThemeForActiveProject()
        startObservingSystemAppearance()   // (re)arm the OS-follow observers
        saveConfig()
    }

    @objc private func setAppearanceSystem(_ sender: Any?) { setAppearanceMode(.system) }
    @objc private func setAppearanceDark(_ sender: Any?) { setAppearanceMode(.dark) }
    @objc private func setAppearanceLight(_ sender: Any?) { setAppearanceMode(.light) }

    /// Ghostty directives Zetty ships as defaults. The user's own config
    /// directives are applied after these, so they win on conflict (ghostty
    /// last-wins semantics for scalar keys).
    private static let defaultGhosttyDirectives: [(key: String, value: String)] = [
        ("shell-integration", "zsh"),
        ("shell-integration-features", "ssh-env,ssh-terminfo"),
    ]

    /// Builds the terminal config: Zetty's default directives, then the
    /// ghostty directives pasted into Zetty's config.
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

    /// Reloads all config from disk (⇧⌘,, like ghostty): re-reads Zetty's
    /// config + the ghostty file, re-resolves appearance/scheme, and re-applies
    /// the theme + terminal overrides to every live pane — no relaunch needed.
    @objc func reloadConfiguration(_ sender: Any?) {
        appConfig = configStore.load()
        applyChromeFontFromConfig()             // hand-edited font directives drive chrome too
        // Theme + appearance pinning route through the per-project decision
        // point (active project's overrides win over the reloaded global).
        applyThemeForActiveProject()
        window?.backgroundColor = ZTheme.current.bg1Color
        startObservingSystemAppearance()
        terminalViewController?.applyTheme()                                  // chrome + terminal theme
        terminalViewController?.reloadGhosttyConfiguration(makeTerminalConfiguration())  // terminal overrides
        if let tvc = terminalViewController {
            applySessionPreservation(to: tvc)                                 // affects new panes only
            applyHomeRoot(to: tvc)                                            // new Home tabs/panes only
            tvc.publishAttentionCount()                                       // re-apply Dock badge gating
            tvc.sidebarPosition = appConfig.sidebarPosition                   // re-pins only on change
            tvc.applyKeyBindings(appConfig.keybindings)                       // prefix/bind/copy-bind lines
        }
    }

    /// Applies a sidebar-position choice live and persists it to the config
    /// (Settings → Appearance).
    func setSidebarPosition(_ position: SidebarPosition) {
        appConfig.sidebarPosition = position
        terminalViewController?.sidebarPosition = position
        saveConfig()
    }

    // MARK: - Font

    /// Renders a font size for the config file: locale-independent, no
    /// trailing ".0" (ghostty parses a plain float; `Double.init` reads it back).
    private static func renderFontSize(_ size: Float) -> String {
        let value = Double(size)
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Coalesces rapid font commits (stepper runs, overlapping combo callbacks)
    /// into one apply — re-fonting every pane + rebuilding chrome per click
    /// makes both visibly stutter.
    private var fontApplyDebounce: DispatchWorkItem?

    /// Applies a Settings font change: persists the ghostty directive at once,
    /// then (debounced) re-fonts every live pane and rescales the chrome.
    private func setGhosttyFontDirective(key: String, value: String?) {
        appConfig = appConfig.settingGhostty(key: key, value: value)
        saveConfig()
        fontApplyDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.terminalViewController?.reloadGhosttyConfiguration(self.makeTerminalConfiguration())
            self.applyChromeFontFromConfig()
            self.terminalViewController?.applyTheme()
        }
        fontApplyDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Threads the effective font directives into `ZTheme` so the chrome
    /// (tabs, sidebar, status bar) tracks the terminal font. Called at startup
    /// and on every config change/reload.
    private func applyChromeFontFromConfig() {
        ZTheme.setFont(
            family: appConfig.ghosttyValue("font-family"),
            size: appConfig.ghosttyValue("font-size").flatMap(Double.init).map { CGFloat($0) }
        )
    }

    // MARK: - Per-project settings

    /// What applies to `project` right now (private override → global).
    /// The fallback name is the folder name, NOT the runtime name — the
    /// runtime name may already carry the override.
    func resolvedSettings(for project: ProjectRuntime) -> ResolvedProjectSettings {
        // A clone without its own settings inherits its source project's
        // (env, theme, preserve-sessions); its own file, once created, wins
        // wholesale. The source's `name` and `icon` are deliberately dropped —
        // an inherited name would rename the clone to match the source (see
        // `updateProjectSettings`'s rename-apply call site), and an inherited
        // icon would suppress the fork glyph that marks the row as a clone.
        let own = projectSettings.settings(for: project.settingsKey)
        let inherited = own == nil
            ? project.cloneSource.flatMap { source in
                projectSettings.settings(for: source).map {
                    var s = $0; s.name = nil; s.icon = nil; return s
                }
            } : nil
        // A clone's fallback is its runtime name ("Zetty/fork-1"), not the
        // directory basename ("zetty-fork-1") — otherwise the launch-time
        // rename-apply pass (`applyProjectNameOverrides`) clobbers every
        // override-less clone's display name on restore.
        let fallbackName = project.isHome ? "Home"
            : project.cloneSource != nil ? project.name
            : (project.rootPath as NSString).lastPathComponent
        return ProjectSettingsResolver.resolve(
            own ?? inherited,
            fallbackName: fallbackName,
            global: appConfig)
    }

    /// Persists new settings for `project` and re-applies everything they
    /// influence: runtime name (+ sidebar re-sort), session preservation for
    /// future panes, and chrome refresh. Notifications are resolved at fire
    /// time, so no re-apply is needed there.
    /// Persists just the active project's broadcast scope. Light on purpose —
    /// broadcast is toggled live, so it skips the rename/re-sort/session re-apply
    /// that `updateProjectSettings` does. `.off` clears the stored field.
    func setBroadcastScope(_ scope: BroadcastScope, for project: ProjectRuntime) {
        var settings = projectSettings.settings(for: project.settingsKey) ?? ProjectSettings()
        settings.broadcastScope = scope.code
        projectSettings.set(settings, for: project.settingsKey)
        try? projectSettingsStore.save(projectSettings)
    }

    func updateProjectSettings(_ new: ProjectSettings, for project: ProjectRuntime) {
        projectSettings.set(new, for: project.settingsKey)
        try? projectSettingsStore.save(projectSettings)
        guard let tvc = terminalViewController else { return }
        if let index = tvc.workspace.projects.firstIndex(where: { $0 === project }) {
            tvc.workspace.rename(projectAt: index, to: resolvedSettings(for: project).name)
        }
        applySessionPreservation(to: tvc)
        if tvc.workspace.activeProject === project {
            applyThemeForActiveProject()   // theme override may have changed
        }
        tvc.refreshSidebar()
        tvc.refreshTabBar()
        scheduleSave()   // runtime name persists via the workspace snapshot
    }

    /// Project menu / ⌥⌘, — opens the ACTIVE project's settings sheet.
    @objc func openActiveProjectSettings(_ sender: Any?) {
        guard let project = terminalViewController?.workspace.activeProject else { return }
        presentProjectSettings(project)
    }

    /// "Project Settings…" sheet: identity + overrides for one project.
    private func presentProjectSettings(_ project: ProjectRuntime, initialTab: String? = nil) {
        guard let window = terminalViewController?.view.window else { return }

        let layoutStatus: () -> String = { [weak self] in
            if let template = ProjectFileIO.load(projectRoot: project.rootPath)?.layoutTemplate {
                return "Repo file — \(template.tabs.count) tab\(template.tabs.count == 1 ? "" : "s")"
            }
            if let template = self?.layoutTemplateStore.load() {
                return "Global default — \(template.tabs.count) tab\(template.tabs.count == 1 ? "" : "s")"
            }
            return "None"
        }

        ProjectSettingsSheet.present(
            for: project.name,
            current: projectSettings.settings(for: project.settingsKey) ?? ProjectSettings(),
            fallbackName: (project.rootPath as NSString).lastPathComponent,
            layoutStatus: layoutStatus,
            onSaveLayout: { [weak self] in
                guard let tvc = self?.terminalViewController else { return }
                var file = ProjectFileIO.load(projectRoot: project.rootPath) ?? ProjectFile()
                file.layoutTemplate = tvc.captureLayoutTemplate(for: project)
                try? ProjectFileIO.save(file, projectRoot: project.rootPath)
            },
            onApplyLayout: { [weak self] in
                guard let self, let tvc = self.terminalViewController else { return }
                let alert = NSAlert()
                alert.messageText = "Apply layout template?"
                alert.informativeText =
                    "This replaces \(project.name)'s current tabs and panes; their sessions end."
                alert.addButton(withTitle: "Apply")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                tvc.applyLayoutTemplate(to: project)
            },
            onClearLayout: {
                guard var file = ProjectFileIO.load(projectRoot: project.rootPath) else { return }
                file.layoutTemplate = nil
                try? ProjectFileIO.save(file, projectRoot: project.rootPath)
            },
            on: window,
            initialTab: initialTab,
            // Unique to Home: every other project is rooted where it was added.
            homeDirectory: project.isHome ? project.rootPath : nil,
            onSaveHomeDirectory: project.isHome ? { [weak self] path in
                self?.setHomeDirectory(path)
            } : nil
        ) { [weak self] edited in
            self?.updateProjectSettings(edited, for: project)
        }
    }

    /// Applies a Home working directory picked in Project Settings: persisted as
    /// the global `zetty-home-path` key (tilde-abbreviated, and cleared outright
    /// when it IS the home directory) so the config stays the one source of
    /// truth, then re-rooted live. New tabs and panes only — a running shell
    /// owns its cwd, and a preserved session captured it at creation.
    private func setHomeDirectory(_ path: String) {
        appConfig.homePath = AppConfig.homePathValue(for: path, defaultHome: NSHomeDirectory())
        saveConfig()
        if let tvc = terminalViewController { applyHomeRoot(to: tvc) }
    }

    /// Re-roots Home from the current config. A moved root is persisted state
    /// and shows in the sidebar row, so a real move saves and re-renders; an
    /// unchanged one does nothing.
    private func applyHomeRoot(to tvc: TerminalViewController) {
        guard tvc.workspace.setHomeRoot(resolvedHomeRoot) else { return }
        tvc.refreshSidebar()
        scheduleSave()
    }

    /// "Rename…" prompt: an NSAlert sheet with a text field (the established
    /// sheet pattern — see confirmRemoveProject). An empty submission clears
    /// the override, restoring the folder name.
    private func promptRenameProject(_ project: ProjectRuntime) {
        guard let window = terminalViewController?.view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Project"
        alert.informativeText = "Leave empty to use the folder name (\((project.rootPath as NSString).lastPathComponent))."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: project.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var settings = self.projectSettings.settings(for: project.settingsKey) ?? ProjectSettings()
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
            settings.name = trimmed.isEmpty ? nil : trimmed
            self.updateProjectSettings(settings, for: project)
        }
    }

    /// Applies stored name overrides to the restored runtimes (called once
    /// right after the workspace is restored, before the first sidebar render).
    /// Iterates a snapshot by identity — each rename resorts the array, so
    /// positional indices from before the rename would go stale.
    private func applyProjectNameOverrides(to tvc: TerminalViewController) {
        for project in Array(tvc.workspace.projects) {
            let resolved = resolvedSettings(for: project)
            if resolved.name != project.name,
               let index = tvc.workspace.projects.firstIndex(where: { $0 === project }) {
                tvc.workspace.rename(projectAt: index, to: resolved.name)
            }
        }
    }

    // MARK: - Session preservation

    /// Threads session preservation into the terminal VC: when enabled and zmx
    /// is installed, new panes launch `zmx attach zetty-<id>` instead of a
    /// bare shell. When restore-scrollback is on, panes launch through the
    /// scrollback-restore wrapper script instead (replays zmx history, then
    /// attaches). Affects NEW panes only. Explicitly closed panes always get
    /// their sessions killed when zmx is present (regardless of the toggle, so
    /// closing panes after disabling still cleans up).
    private func applySessionPreservation(to tvc: TerminalViewController) {
        let zmxPath = ZmxRunner.locate()

        // The provider must be installed if ANY project can preserve — the
        // global toggle or a per-project override forcing it on. The
        // per-pane decision happens inside the closure at spawn time.
        let anyPreserve = appConfig.preserveSessions || projectSettings.anyPreserveOverrideOn
        if anyPreserve, let zmx = zmxPath {
            let restoreScript = appConfig.restoreScrollback ? ScrollbackRestore.ensureScript() : nil
            tvc.sessionCommandProvider = { [weak self, weak tvc] id in
                guard let self else { return nil }
                // Resolve the owning project's effective value; a surface not
                // yet in the model (shouldn't happen) follows the global.
                if let project = tvc?.workspace.project(containing: id) {
                    // Scratch terminals are ephemeral — always a plain shell.
                    if project.isScratch { return nil }
                    guard self.resolvedSettings(for: project).preserveSessions else { return nil }
                } else {
                    guard self.appConfig.preserveSessions else { return nil }
                }
                return SessionPersistence.attachCommand(
                    zmxPath: zmx, surfaceID: id, restoreScriptPath: restoreScript)
            }
        } else {
            tvc.sessionCommandProvider = nil
            if anyPreserve { presentZmxMissingAlertOnce() }
        }

        if let zmx = zmxPath {
            tvc.onSurfacesClosed = { ids in
                ZmxRunner.kill(sessions: ids.map(SessionPersistence.sessionName(for:)), zmxPath: zmx)
            }
        } else {
            tvc.onSurfacesClosed = nil
        }
    }

    /// One-shot startup reap: kills Zetty zmx sessions that no restored
    /// surface owns. Clean quits kill sessions on explicit close, so orphans
    /// only appear after crashes or workspace-file loss; without this they
    /// would accumulate silently (Settings also offers a manual kill).
    private func reapOrphanSessions(_ tvc: TerminalViewController) {
        guard let zmx = ZmxRunner.locate() else { return }
        // Ownership, NOT attachment: hibernating frees a project's sessions only
        // best-effort, so a hibernated project's surface may still have one.
        // `allSurfaceIDs` excludes those surfaces, which made any such session
        // look orphaned and killed it on launch — unattended, since
        // auto-hibernation needs no user action.
        let liveIDs = tvc.sessionOwnerSurfaceIDs
        DispatchQueue.global(qos: .utility).async {
            let existing = ZmxRunner.listZettySessions(zmxPath: zmx)
            let orphans = SessionPersistence.orphans(existing: existing, liveSurfaceIDs: liveIDs)
            ZmxRunner.kill(sessions: orphans, zmxPath: zmx)
        }
    }

    /// Shown once per run when libghostty rejected the merged terminal config.
    /// Ghostty validates all-or-nothing, so one bad directive drops every
    /// custom setting; panes keep working (Zetty's own directives are re-applied
    /// alone) but the user's passthrough is inert until the key is fixed.
    private var ghosttyConfigRejectedAlertShown = false

    private func presentGhosttyConfigRejectedAlertOnce(issue: String?) {
        guard !ghosttyConfigRejectedAlertShown else { return }
        ghosttyConfigRejectedAlertShown = true
        let unsupported = appConfig.unsupportedKeys
        let configPath = ConfigStore().fileURL.path
        // Deferred: this fires while a pane's surface is being built, and a modal
        // must not run inside that.
        DispatchQueue.main.async {
            let cause = issue ?? (unsupported.isEmpty
                ? "Check for a misspelled key."
                : "Unrecognized Zetty keys: \(unsupported.joined(separator: ", ")).")
            let alert = NSAlert()
            // "Some … were ignored" undersold it: ghostty validates
            // all-or-nothing, so one bad line drops EVERY pasted setting. The
            // title now matches what the body already said.
            alert.messageText = "Your terminal settings aren't being applied"
            alert.informativeText = """
            One line in \(configPath) was rejected, and the terminal accepts your \
            settings all together or not at all — so every pasted ghostty setting \
            (fonts, colors, …) is currently being ignored.

            \(cause)

            Panes still run normally — session preservation is unaffected.
            """
            alert.runModal()
        }
    }

    /// One-time guidance when `preserve-sessions = true` was set by hand but
    /// zmx isn't installed (the Settings toggle drives an install instead).
    private func presentZmxMissingAlertOnce() {
        let key = "Zetty.zmxMissingAlertShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.async {
            let alert = NSAlert()
            // Leads with the consequence, not the config key, and matches the
            // wording Settings uses for the same condition ("Session
            // preservation requires zmx") so the two don't read as two problems.
            alert.messageText = "Session preservation needs zmx, which isn't installed"
            alert.informativeText = """
            Your config sets preserve-sessions = true. Until zmx is installed, panes \
            run plain shells — whatever is running in them ends when Zetty quits.

            Settings (⌘,) can install it for you.

            \(ZmxRunner.installHint)
            """
            alert.runModal()
        }
    }

    // MARK: - Settings

    private var settingsWindowController: SettingsWindowController?

    @objc private func openSettings(_ sender: Any?) {
        let controller = settingsWindowController ?? SettingsWindowController(
            installer: hookInstaller,
            liveSurfaceIDs: { [weak self] in self?.terminalViewController?.sessionOwnerSurfaceIDs ?? [] }
        )
        controller.onSetAppearance = { [weak self] mode in self?.setAppearanceMode(mode) }
        controller.onSelectTheme = { [weak self] scheme in self?.selectTheme(scheme) }
        controller.onSetSidebarPosition = { [weak self] position in self?.setSidebarPosition(position) }
        controller.onSetFontFamily = { [weak self] family in
            self?.setGhosttyFontDirective(key: "font-family", value: family)
        }
        controller.onSetFontSize = { [weak self] size in
            self?.setGhosttyFontDirective(key: "font-size", value: size.map(Self.renderFontSize))
        }
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

    // MARK: - Agent notifications

    /// An agent transitioned into needs-attention. Config-gated levels:
    /// attention sound, Dock badge (follows the attention count, applied in
    /// the count callback), and a macOS notification — posted only while
    /// Zetty is in the background (in front, the sound + yellow dots
    /// already tell the story). Gating uses the project's RESOLVED settings
    /// (per-project override folded over the global notify-* keys).
    private func agentNeedsAttention(surface: Surface, kind: AgentKind, project: ProjectRuntime) {
        let resolved = resolvedSettings(for: project)
        if resolved.notifySound {
            NSSound(named: "Ping")?.play()
            if !NSApp.isActive {
                NSApp.requestUserAttention(.informationalRequest)   // one Dock bounce
            }
        }
        guard resolved.notifySystem, !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(kind.displayName.capitalized) needs attention"
            content.body = "\(project.name) — \(surface.workingDir)"
            content.userInfo = ["pane": SessionPersistence.shortID(for: surface.id)]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // (UNUserNotificationCenterDelegate conformance in the extension below.)

    /// App menu Close / ⌘H: use the exact retained-window handoff owned by
    /// `windowShouldClose`, matching the main window's red close button.
    @objc private func closeApplication(_ sender: Any?) {
        window?.performClose(sender)
    }

    /// App menu Quit / ⌘Q: explicit intent to close the app while leaving
    /// preserved zmx sessions available for the next launch.
    @objc private func quitApplication(_ sender: Any?) {
        requestApplicationTermination(killingSessions: false)
    }

    /// App menu full shutdown. Unlike Quit, this always confirms because every
    /// Zetty-owned preserved session and its running processes will be ended.
    @objc private func shutDownApplication(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Shut Down Zetty?"
        alert.informativeText = "All running processes and preserved terminal sessions will be ended. This cannot be undone."
        alert.addButton(withTitle: "Shut Down")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        requestApplicationTermination(killingSessions: true)
    }

    /// Shared exit primitive for App menu actions and the control CLI. Session
    /// cleanup is blocking process IO, so it completes off-main before AppKit is
    /// asked to terminate. `applicationWillTerminate` then saves the workspace
    /// and stops the control socket.
    private func requestApplicationTermination(killingSessions: Bool) {
        precondition(Thread.isMainThread)

        guard killingSessions, let zmx = ZmxRunner.locate() else {
            NSApp.terminate(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let sessions = ZmxRunner.listZettySessions(zmxPath: zmx)
            ZmxRunner.killAndWait(sessions: sessions, zmxPath: zmx)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// The main window's close button (red x) hides the retained window while
    /// leaving every surface, service, and session alive. The status item is the
    /// handoff back into the running workspace.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        installStatusItem()
        _ = NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { NSApp.hide(nil) }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let mainWindow = window,
              notification.object as? NSWindow === mainWindow else { return }
        removeStatusItem()
    }

    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_: Notification) {
        controlSocketServer?.stop()
        saveWorkspace()
    }

    // MARK: - Control socket (Zetty CLI)

    private var controlSocketServer: ControlSocketServer?

    /// Hosts `~/.zetty/zetty.sock` for the `zetty` CLI: status snapshot,
    /// input injection (`send`), and config reload.
    ///
    /// The server invokes this handler on its own socket queue. Fast verbs
    /// hop to main (they read UI/workspace state); `capture`'s blocking
    /// `zmx history` subprocess and `quit --kill-sessions`' kill-wait run
    /// off-main so a slow/hung zmx can't freeze the UI.
    private func startControlSocket() {
        let server = ControlSocketServer { [weak self] request in
            guard let self else { return .error("Zetty is shutting down") }
            switch request {
            case .capture(let target, let lines):
                let resolved = DispatchQueue.main.sync { () -> Result<TerminalViewController.CaptureSource, ControlError> in
                    guard let tvc = self.terminalViewController else {
                        return .failure(.protocolError("Zetty is still starting up"))
                    }
                    return tvc.captureSource(target: target)
                }
                switch resolved {
                case .failure(let error):
                    return .error(error.localizedDescription)
                case .success(let source):
                    guard let history = ZmxRunner.history(session: source.session, zmxPath: source.zmxPath) else {
                        return .error(
                            "no captured output — pane \(source.paneID) has no preserved session (preserve-sessions off?)"
                        )
                    }
                    let allLines = history.split(separator: "\n", omittingEmptySubsequences: false)
                    let tail = lines.map { Array(allLines.suffix(max(0, $0))) } ?? Array(allLines)
                    return .text(tail.joined(separator: "\n"))
                }
            case .quit(let killSessions):
                // Respond first; the shared helper performs any kill-wait
                // off-main, then terminates without displaying a GUI prompt.
                DispatchQueue.main.async {
                    self.requestApplicationTermination(killingSessions: killSessions)
                }
                return .ok
            case .cloneProject(let project, let name, let focus):
                // Plan on main (workspace state), copy on this socket queue (cp can be
                // slow on a non-APFS fallback), register on main.
                let planned = DispatchQueue.main.sync { () -> Result<ClonePlan, ControlError> in
                    guard let tvc = self.terminalViewController else {
                        return .failure(.protocolError("Zetty is still starting up"))
                    }
                    return tvc.planClone(projectName: project, cloneName: name)
                }
                switch planned {
                case .failure(let error):
                    return .error(error.localizedDescription)
                case .success(let plan):
                    // Spinner row under the source while the copy runs on this
                    // socket queue (mirrors the GUI clone's feedback).
                    let pendingToken = DispatchQueue.main.sync {
                        self.terminalViewController?.beginPendingClone(plan: plan)
                    }
                    let cloneResult = CloneRunner.clone(plan)
                    return DispatchQueue.main.sync {
                        guard let tvc = self.terminalViewController else {
                            return .error("Zetty is shutting down")
                        }
                        if let pendingToken { tvc.endPendingClone(pendingToken) }
                        switch cloneResult {
                        case .failure(let failure):
                            return .error(failure.message)
                        case .success(let outcome):
                            switch tvc.registerClone(plan: plan, outcome: outcome, focus: focus) {
                            case .success(let pane): return .pane(pane)
                            case .failure(let error): return .error(error.localizedDescription)
                            }
                        }
                    }
                }
            case .removeProject(let name, let fetch, let discard):
                // Plan on main (workspace state); a clone's git probe/fetch-back
                // runs on this socket queue so a slow `git fetch` can't beachball
                // the app; the actual removal happens back on main.
                let planned = DispatchQueue.main.sync { () -> Result<TerminalViewController.RemoveProjectPlan, ControlError> in
                    guard let tvc = self.terminalViewController else {
                        return .failure(.protocolError("Zetty is still starting up"))
                    }
                    return .success(tvc.planRemoveProject(name: name, fetch: fetch, discard: discard))
                }
                switch planned {
                case .failure(let error):
                    return .error(error.localizedDescription)
                case .success(.failed(let message)):
                    return .error(message)
                case .success(.completed):
                    return .ok
                case .success(.clonePending(let cloneID, let cloneRoot, let sourceRoot)):
                    // No dialogs on the CLI — unsaved work demands an explicit flag.
                    let state = CloneRunner.probeWorkState(cloneRoot: cloneRoot, sourceRoot: sourceRoot)
                    if state != .clean && !fetch && !discard {
                        return .error(
                            "clone has unsaved work — pass --fetch to land its branch in the"
                            + " original first, or --discard to delete anyway")
                    }
                    if fetch {
                        guard let branch = CloneRunner.currentBranch(in: cloneRoot) else {
                            return .error(
                                "fetch-back failed — the clone has no current branch"
                                + " (detached HEAD?); nothing was deleted")
                        }
                        if let error = CloneRunner.fetchBack(sourceRoot: sourceRoot, clonePath: cloneRoot,
                                                             branch: branch) {
                            return .error("fetch-back failed — nothing was deleted: \(error)")
                        }
                    }
                    return DispatchQueue.main.sync {
                        guard let tvc = self.terminalViewController else {
                            return .error("Zetty is shutting down")
                        }
                        if let message = tvc.completeRemoveClone(cloneID: cloneID, cloneRoot: cloneRoot) {
                            return .error(message)
                        }
                        return .ok
                    }
                }
            case .updateClone(let name):
                let planned = DispatchQueue.main.sync { () -> TerminalViewController.UpdateClonePlan in
                    guard let tvc = self.terminalViewController else {
                        return .failed("Zetty is still starting up")
                    }
                    return tvc.planUpdateClone(name: name)
                }
                switch planned {
                case .failed(let message):
                    return .error(message)
                case .ready(let cloneRoot, let sourceRoot):
                    switch CloneRunner.updateFromSource(cloneRoot: cloneRoot, sourceRoot: sourceRoot) {
                    case .updated(let summary):
                        return .text(summary)
                    case .upToDate:
                        return .text("already up to date with the source")
                    case .conflicts(let files):
                        return .error("merge conflicts left in the clone — resolve them there, then "
                            + "commit and PR. Conflicting files:\n" + files.joined(separator: "\n"))
                    case .refused(let message):
                        return .error(message)
                    case .failed(let message):
                        return .error(message)
                    }
                }
            default:
                return DispatchQueue.main.sync { self.handleOnMain(request) }
            }
        }
        server.start()
        controlSocketServer = server
    }

    /// Fast control verbs — must run on the main thread (UI/workspace state).
    private func handleOnMain(_ request: ControlRequest) -> ControlResponse {
        guard let tvc = terminalViewController else {
            return .error("Zetty is still starting up")
        }
        switch request {
        case .status:
            return .status(tvc.statusSnapshot())
        case .reload:
            self.reloadConfiguration(nil)
            return .ok
        case .viewFile(let path, let line, let column):
            if let message = tvc.presentFileViewer(path: path, line: line, column: column) {
                return .error(message)
            }
            return .ok
        case .scratch(let focus):
            return .pane(tvc.newScratchTerminal(focus: focus))
        case .scratchClear:
            tvc.closeAllScratchTerminals()
            return .ok
        case .send(let target, let text, let enter, let keys):
            if let message = tvc.sendInput(target: target, text: text, enter: enter, keys: keys) {
                return .error(message)
            }
            return .ok
        case .newTab(let project, let focus):
            switch tvc.openNewTab(inProject: project, focus: focus) {
            case .success(let pane): return .pane(pane)
            case .failure(let error): return .error(error.localizedDescription)
            }
        case .addProject(let path, let name, let focus):
            switch tvc.addProject(path: path, name: name, focus: focus) {
            case .success(let pane): return .pane(pane)
            case .failure(let error): return .error(error.localizedDescription)
            }
        case .hibernateProject(let name):
            if let message = tvc.hibernateProjectNamed(name) { return .error(message) }
            return .ok
        case .wakeProject(let name):
            if let message = tvc.wakeProjectNamed(name) { return .error(message) }
            return .ok
        case .newProject(let path, let name, let gitInit, let focus):
            switch tvc.newProject(path: path, name: name, gitInit: gitInit, focus: focus) {
            case .success(let pane): return .pane(pane)
            case .failure(let error): return .error(error.localizedDescription)
            }
        case .close(let target, let wholeTab):
            if let message = tvc.closePane(target: target, wholeTab: wholeTab) {
                return .error(message)
            }
            return .ok
        case .split(let target, let vertical, let focus):
            switch tvc.splitPane(target: target, vertical: vertical, focus: focus) {
            case .success(let pane): return .pane(pane)
            case .failure(let error): return .error(error.localizedDescription)
            }
        case .breakPane(let target, let focus):
            switch tvc.breakPaneToTab(target: target, focus: focus) {
            case .success(let pane): return .pane(pane)
            case .failure(let error): return .error(error.localizedDescription)
            }
        case .focus(let target):
            if let message = tvc.focusPane(target: target) {
                return .error(message)
            }
            return .ok
        case .capture, .quit, .cloneProject, .removeProject, .updateClone:
            // Slow verbs — handled on the socket queue in startControlSocket.
            return .error("internal: slow verb routed to the main handler")
        }
    }

    // MARK: - Persistence helpers

    /// Directory the Home project is rooted at: the resolved `zetty-home-path`
    /// when it still names an existing directory, else the account's home
    /// directory.
    ///
    /// A bad path degrades to `~` with a log line rather than an alert: Home is
    /// the guaranteed floor of the sidebar and must always open somewhere, and
    /// the same config is re-read on every ⇧⌘, — an alert per reload while a
    /// volume is unmounted would be worse than a quiet, discoverable fallback
    /// (`log show --predicate 'subsystem == "co.webteractive.zetty"'`).
    private var resolvedHomeRoot: String {
        let home = NSHomeDirectory()
        // Standardized like `addProject` does, so `zetty add-project` still
        // recognises this directory as already taken by Home.
        let path = URL(fileURLWithPath: appConfig.resolvedHomePath(defaultHome: home))
            .standardizedFileURL.path
        guard path != home else { return home }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            ZettyLog.config.error("zetty-home-path: \(path) is not an existing directory — Home stays at \(home)")
            return home
        }
        return path
    }

    /// Load the saved workspace and seed the terminal view controller with it.
    ///
    /// Restoration is unconditional — even if `preserveSessions` is false in the
    /// persisted project, we still restore the tab layout.  On any error (missing
    /// file, corrupt JSON) this silently falls back to the default fresh-tab layout
    /// so the app never crashes on bad data.
    ///
    /// Returns true only when a saved workspace was actually decoded and
    /// restored. Callers MUST NOT reap "orphan" zmx sessions otherwise: after
    /// a fallback, no session is owned by a restored surface, and reaping
    /// would kill every preserved session — the user's running work — over a
    /// merely missing/corrupt layout file.
    @discardableResult
    private func restoreWorkspace(into tvc: TerminalViewController) -> Bool {
        // Home follows the config, not the rootPath saved in workspace.json —
        // that's what lets `zetty-home-path` move it (and lets dropping the key
        // move it back). Applied to the fallback model too, since a missing or
        // corrupt layout file must not strand Home at ~.
        let homeRoot = resolvedHomeRoot
        tvc.workspace.setHomeRoot(homeRoot)
        do {
            let workspace = try workspaceStore.load()
            tvc.restoreSidebar(collapsed: workspace.sidebarCollapsed, width: workspace.sidebarWidth)
            let runtimes = SessionSnapshot.projectRuntimes(from: workspace)
            // Empty runtimes → fall back to the default WorkspaceModel already in
            // tvc (keeps the reap-safety contract: no restored surfaces to own).
            guard !runtimes.isEmpty else { return false }
            // `restored(from:)` guarantees a Home exists (injecting one for
            // pre-Home saved files) and never returns nil for non-empty input.
            if let model = WorkspaceModel.restored(from: runtimes,
                                                   spaces: workspace.spaces,
                                                   activeIndex: workspace.activeProjectIndex,
                                                   homeRoot: homeRoot) {
                tvc.restore(workspace: model)
                return true
            }
            return false
        } catch {
            // Corrupt or unreadable — start fresh (tvc already has a default model).
            return false
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
        var workspace = SessionSnapshot.workspace(from: tvc.currentWorkspace)
        let sidebar = tvc.sidebarStateForPersistence
        workspace.sidebarCollapsed = sidebar.collapsed
        workspace.sidebarWidth = sidebar.width
        try? workspaceStore.save(workspace)
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
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

    // MARK: - Hidden-window status menu

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.title = "Z"
            button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
            button.toolTip = "Zetty"
            button.setAccessibilityLabel("Zetty")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func showMainWindow() {
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        removeStatusItem()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let statusMenu = statusItem?.menu, menu === statusMenu else { return }
        rebuildStatusMenu(menu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let showItem = NSMenuItem(
            title: "Show Zetty",
            action: #selector(showZettyFromStatusMenu(_:)),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)

        let projects = terminalViewController?.menuBarSnapshot() ?? []
        if !projects.isEmpty {
            menu.addItem(.separator())
            for project in projects {
                if project.tabs.count == 1, let tab = project.tabs.first {
                    let item = statusMenuItem(
                        title: project.title,
                        projectID: project.id,
                        tabIndex: tab.index,
                        status: tab.status
                    )
                    item.state = project.isActive ? .on : .off
                    menu.addItem(item)
                    continue
                }

                let projectItem = NSMenuItem(title: project.title, action: nil, keyEquivalent: "")
                applyStatus(project.status, title: project.title, to: projectItem)
                projectItem.state = project.isActive ? .on : .off
                let submenu = NSMenu(title: project.title)
                for tab in project.tabs {
                    let item = statusMenuItem(
                        title: tab.title,
                        projectID: project.id,
                        tabIndex: tab.index,
                        status: tab.status
                    )
                    item.state = tab.isActive ? .on : .off
                    submenu.addItem(item)
                }
                projectItem.submenu = submenu
                menu.addItem(projectItem)
            }
        }
    }

    private func statusMenuItem(
        title: String,
        projectID: UUID,
        tabIndex: Int?,
        status: AgentStatus?
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(selectStatusMenuDestination(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = StatusMenuDestination(projectID: projectID, tabIndex: tabIndex)
        applyStatus(status, title: title, to: item)
        return item
    }

    private func applyStatus(_ status: AgentStatus?, title: String, to item: NSMenuItem) {
        guard let status, let color = agentStatusColor(status) else { return }
        let attributedTitle = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: color]
        )
        attributedTitle.append(NSAttributedString(string: title))
        item.attributedTitle = attributedTitle

        let accessibleTitle = "\(title), \(status.statusMenuDescription)"
        item.toolTip = accessibleTitle
        item.setAccessibilityLabel(accessibleTitle)
    }

    @objc private func showZettyFromStatusMenu(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func selectStatusMenuDestination(_ sender: NSMenuItem) {
        if let destination = sender.representedObject as? StatusMenuDestination {
            _ = terminalViewController?.selectAwakeProject(
                id: destination.projectID,
                tabIndex: destination.tabIndex
            )
        }
        showMainWindow()
    }

    // MARK: - Application menu bar

    /// Builds the full menu bar programmatically.
    ///
    /// We bootstrap without a storyboard (see `main.swift`) so AppKit never
    /// loads a `Main.storyboard`; without an explicit menu, the app has no
    /// Quit item or standard shortcuts.  This method creates the minimal set of
    /// menus Zetty needs.
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

        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkUpdatesItem.target = self
        appMenu.addItem(checkUpdatesItem)

        let reloadConfig = NSMenuItem(
            title: "Reload Configuration",
            action: #selector(reloadConfiguration(_:)),
            keyEquivalent: ","
        )
        reloadConfig.keyEquivalentModifierMask = [.command, .shift]
        reloadConfig.target = self
        appMenu.addItem(reloadConfig)
        appMenu.addItem(.separator())

        let closeItem = NSMenuItem(
            title: "Close Zetty",
            action: #selector(closeApplication(_:)),
            keyEquivalent: "h"
        )
        closeItem.keyEquivalentModifierMask = [.command]
        closeItem.target = self
        appMenu.addItem(closeItem)

        let quitItem = NSMenuItem(
            title: "Quit Zetty",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        appMenu.addItem(quitItem)

        let shutDownItem = NSMenuItem(
            title: "Shutdown Zetty",
            action: #selector(shutDownApplication(_:)),
            keyEquivalent: ""
        )
        shutDownItem.target = self
        appMenu.addItem(shutDownItem)

        // ── Shell menu ────────────────────────────────────────────────────────
        let shellMenuItem = NSMenuItem()
        mainMenu.addItem(shellMenuItem)
        let shellMenu = NSMenu(title: "Shell")
        shellMenuItem.submenu = shellMenu

        // "New Scratch Terminal"  ⌃⌘N — a project-less, ephemeral terminal in
        // the Scratch sidebar section. Routed to the TVC by the loop below.
        let newScratch = NSMenuItem(
            title: "New Scratch Terminal",
            action: #selector(TerminalViewController.newScratchTerminal(_:)),
            keyEquivalent: "n"
        )
        newScratch.keyEquivalentModifierMask = [.command, .control]
        shellMenu.addItem(newScratch)

        shellMenu.addItem(.separator())

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

        // "Resize Pane …"  ⌥⌘←/→/↑/↓ — nudge the focused pane's divider.
        let resizeSpecs: [(String, Selector, Int)] = [
            ("Resize Pane Left", #selector(TerminalViewController.resizePaneLeft(_:)), NSLeftArrowFunctionKey),
            ("Resize Pane Right", #selector(TerminalViewController.resizePaneRight(_:)), NSRightArrowFunctionKey),
            ("Resize Pane Up", #selector(TerminalViewController.resizePaneUp(_:)), NSUpArrowFunctionKey),
            ("Resize Pane Down", #selector(TerminalViewController.resizePaneDown(_:)), NSDownArrowFunctionKey),
        ]
        for (title, selector, arrowKey) in resizeSpecs {
            let item = NSMenuItem(
                title: title,
                action: selector,
                keyEquivalent: String(UnicodeScalar(UInt16(arrowKey))!)
            )
            item.keyEquivalentModifierMask = [.command, .option]
            shellMenu.addItem(item)
        }

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

        // "Break Pane into Tab"  ⌥⌘T
        let breakPane = NSMenuItem(
            title: "Break Pane into Tab",
            action: #selector(TerminalViewController.breakPaneIntoTab(_:)),
            keyEquivalent: "t"
        )
        breakPane.keyEquivalentModifierMask = [.command, .option]
        shellMenu.addItem(breakPane)

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

        // "Select Tab N"  ⌘1…⌘9 — the item tag carries the zero-based index.
        for number in 1...9 {
            let item = NSMenuItem(
                title: "Select Tab \(number)",
                action: #selector(TerminalViewController.selectTabByNumber(_:)),
                keyEquivalent: "\(number)"
            )
            item.keyEquivalentModifierMask = [.command]
            item.tag = number - 1
            shellMenu.addItem(item)
        }

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

        // "Toggle File Tree"  ⇧⌘F — "F for files". Command rather than Control
        // so the chord never reaches the pty: menu key equivalents are resolved
        // in NSApplication.sendEvent before the terminal surface sees the
        // event, and a Control chord bound here would permanently swallow a
        // keystroke the shell might want. `Ctrl+B e` does the same on the
        // prefix layer and stays rebindable.
        //
        // Note for whoever adds project-wide content search later: ⇧⌘F is what
        // VS Code and Zed use for exactly that, and it is spent here. Pick
        // another chord rather than stealing this one back.
        let toggleFileTree = NSMenuItem(
            title: "Toggle File Tree",
            action: #selector(TerminalViewController.toggleFileTree(_:)),
            keyEquivalent: "F"
        )
        toggleFileTree.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(toggleFileTree)

        // "Scroll to Bottom"  ⌘↓ — rejoin the live tail after scrolling back
        // through a long log. ⌥⌘↓ is Resize Pane Down; plain ⌘↓ is free, and
        // the prefix/copy-mode `down` bindings are mode-scoped so they don't
        // collide with a native equivalent.
        let scrollBottom = NSMenuItem(
            title: "Scroll to Bottom",
            action: #selector(TerminalViewController.scrollToBottom(_:)),
            keyEquivalent: String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        )
        scrollBottom.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(scrollBottom)

        // "Cycle Broadcast"  ⇧⌘B — mirrors Cycle Appearance / Cycle Color Scheme:
        // one shortcut steps Off → Tab → Project → Agents → Workspace → Off.
        let cycleBroadcast = NSMenuItem(
            title: "Cycle Broadcast Input",
            action: #selector(TerminalViewController.broadcastCycle(_:)),
            keyEquivalent: "B"
        )
        cycleBroadcast.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(cycleBroadcast)

        // "Broadcast Input" submenu — synchronized input across panes.
        let broadcastItem = NSMenuItem()
        broadcastItem.title = "Broadcast Input"
        let broadcastMenu = NSMenu(title: "Broadcast Input")
        broadcastItem.submenu = broadcastMenu
        for (title, action) in [
            ("Off", #selector(TerminalViewController.broadcastOff(_:))),
            ("Tab", #selector(TerminalViewController.broadcastTab(_:))),
            ("Project", #selector(TerminalViewController.broadcastProject(_:))),
            ("Agents", #selector(TerminalViewController.broadcastAgents(_:))),
            ("Workspace", #selector(TerminalViewController.broadcastWorkspace(_:))),
        ] {
            broadcastMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        viewMenu.addItem(broadcastItem)

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

        // "Add Project…"  ⌘O — the unified picker (choose or create a folder,
        // with an "Initialize git repository" checkbox).
        let addProject = NSMenuItem(
            title: "Add Project\u{2026}",
            action: #selector(TerminalViewController.addProject(_:)),
            keyEquivalent: "o"
        )
        addProject.keyEquivalentModifierMask = [.command]
        projectMenu.addItem(addProject)

        // Hidden alternate so the old New-Project ⇧⌘N muscle memory still opens
        // the same picker (a hidden item still fires its key equivalent).
        let addProjectAlt = NSMenuItem(
            title: "Add Project\u{2026}",
            action: #selector(TerminalViewController.addProject(_:)),
            keyEquivalent: "n"
        )
        addProjectAlt.keyEquivalentModifierMask = [.command, .shift]
        addProjectAlt.isHidden = true
        projectMenu.addItem(addProjectAlt)

        // "Project Settings…"  ⌥⌘, — the ACTIVE project's settings sheet
        // (comma mirrors the app-wide Settings ⌘, convention).
        let projectSettings = NSMenuItem(
            title: "Project Settings\u{2026}",
            action: #selector(openActiveProjectSettings(_:)),
            keyEquivalent: ","
        )
        projectSettings.keyEquivalentModifierMask = [.command, .option]
        projectSettings.target = self
        projectMenu.addItem(projectSettings)

        // "Remove Project…" — no shortcut (destructive); disabled on the last
        // project via the TVC's menu validation.
        let removeProject = NSMenuItem(
            title: "Remove Project\u{2026}",
            action: #selector(TerminalViewController.removeProject(_:)),
            keyEquivalent: ""
        )
        projectMenu.addItem(removeProject)

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

private extension AgentStatus {
    var statusMenuDescription: String {
        switch self {
        case .running: return "running"
        case .needsAttention: return "needs attention"
        case .idle: return "idle"
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Clicking a needs-attention notification focuses the pane it came from.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let pane = response.notification.request.content.userInfo["pane"] as? String {
            DispatchQueue.main.async { [weak self] in
                self?.showMainWindow()
                _ = self?.terminalViewController?.focusPane(target: .pane(pane))
            }
        }
        completionHandler()
    }
}
