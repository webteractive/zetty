import AppKit
import GhosttyTerminal
import QuerttyCore
import QuerttyGhostty

// MARK: - TerminalViewController

/// Hosts a recursive split-pane terminal layout driven by a `PaneTree`,
/// with full tab support via `TabList` and project management via `WorkspaceModel`.
///
/// # Layout model
/// `paneTree.layout.root` is a `SurfaceNode` tree.  Each time the tree
/// changes, `rebuildSurfaceNodeView()` replaces the root content view with a
/// fresh `SurfaceNodeView`.  Unchanged leaf panes share their persistent
/// `TerminalView` from `registry`, so splits never kill a sibling session.
///
/// # Tab model
/// A `TabList` holds one `PaneTree` per tab.  The computed `paneTree`
/// property forwards to `workspace.activeTabList.activeTree`, so all `PaneActions`
/// methods operate on the active tab without modification.
///
/// # Project model
/// A `WorkspaceModel` holds one `ProjectRuntime` (each with its own `TabList`)
/// per project.  Switching projects swaps the entire tab+pane area.
///
/// # Registry pruning
/// After each rebuild the registry is pruned to the UNION of surface IDs across
/// ALL projects' ALL tabs.  Background tabs and projects keep their live PTY
/// sessions; only truly closed surfaces are torn down.
///
/// # Session ownership
/// The live PTY lives inside `TerminalView` (AppTerminalView) via its
/// embedded `TerminalSurfaceCoordinator → TerminalSurface`.
/// `SurfaceRegistry` retains both; `prune(keeping:)` tears down removed panes.
final class TerminalViewController: NSViewController {

    // MARK: - State

    /// Shared registry — persists terminal views across re-renders, tab switches,
    /// and project switches.
    private let registry = SurfaceRegistry()

    /// Workspace model — ordered list of projects, each owning its own TabList.
    private var workspace = WorkspaceModel()

    /// The logical pane tree for the ACTIVE tab in the ACTIVE project.  Mutate
    /// this, then call `rebuildSurfaceNodeView()`.  Declared `internal` so the
    /// `PaneActions` extension (same module) can write it.
    var paneTree: PaneTree {
        get { workspace.activeTabList.activeTree }
        set { workspace.activeTabList.activeTree = newValue }
    }

    /// The currently installed root content view (a `SurfaceNodeView`).
    private var rootContentView: SurfaceNodeView?

    /// The tab bar strip shown above the pane area.
    private var tabBarView: TabBarView?

    /// The project sidebar shown on the left.
    private var sidebarView: SidebarView?

    /// The bottom status strip (cwd · scheme · shell · libghostty version).
    private var statusBarView: StatusBarView?

    /// The command palette overlay, when open.
    private var commandPaletteView: CommandPaletteView?

    /// Per-session AI-agent state, driven by harness-hook events.
    private let agentDetector = AgentDetector()
    /// Watches the hook event sink (`~/.quertty/agent-events.jsonl`).
    private var agentEventWatcher: AgentEventWatcher?

    /// Foreground command per preserved pane, from the zmx/ps probe. This is
    /// the identity used for tab logos/names; hook events only drive the
    /// status dots. Known agents get brand logos; other tools (vim, nano)
    /// get one when we bundle it.
    private var foregroundBySurface: [UUID: String] = [:]
    private var foregroundPollTimer: Timer?

    /// The pinned libghostty-spm version (no runtime version API is exposed).
    /// Keep in sync with `Project.swift`'s package requirement.
    private static let libghosttyVersion = "1.2.7"

    /// Background queue + debounce for `git` probes feeding the status bar.
    private let gitQueue = DispatchQueue(label: "dev.more.quertty.git", qos: .utility)
    private var gitProbeWork: DispatchWorkItem?

    /// The container that wraps the tab-bar + pane area (right side of the split).
    private var contentContainer: NSView?

    /// The 1pt divider between the sidebar and content (retained so it can be
    /// recolored when the scheme changes).
    private var separatorView: NSView?

    /// Sidebar width, and the leading constraint we animate to collapse it.
    private let sidebarWidth: CGFloat = 244
    private var sidebarLeadingConstraint: NSLayoutConstraint?
    private var sidebarCollapsed = false

    /// KVO token for observing `window.firstResponder`.
    private var firstResponderObservation: NSKeyValueObservation?

    /// Called after any change that affects persisted workspace state (tab
    /// add/close, split/close, project add/pin, rename). The owner (AppDelegate)
    /// uses this to autosave, so the on-disk workspace always reflects the
    /// current arrangement — surviving crashes/force-quits, not just clean quit.
    var onWorkspaceDidChange: (() -> Void)?

    /// Called to switch to a specific color scheme (owner applies + persists).
    var onSelectScheme: ((QColorScheme) -> Void)?

    /// Called to cycle to the next color scheme (⌘⇧T).
    var onCycleScheme: (() -> Void)?

    /// Called to switch the appearance axis (system / dark / light).
    var onSetAppearance: ((AppearanceMode) -> Void)?

    /// Called to cycle the appearance axis (status-bar switcher).
    var onCycleAppearance: (() -> Void)?

    /// Supplies the current appearance-mode display name ("System"/"Dark"/"Light").
    var appearanceModeName: (() -> String)?

    /// Ghostty config (user's ghostty file + `ghostty.*` passthrough). Set by the
    /// owner before the view loads so the first panes pick it up.
    var ghosttyConfiguration: TerminalConfiguration?

    /// When set, new panes launch this command instead of the default shell
    /// (session preservation: `zmx attach quertty-<id>`). Affects NEW panes only.
    var sessionCommandProvider: ((UUID) -> String?)? {
        didSet {
            registry.surfaceCommand = sessionCommandProvider.map { provider in
                { surface in provider(surface.id) }
            }
        }
    }

    /// Called with surface IDs removed by an explicit close (pane/tab/project),
    /// so their persistent sessions can be killed. App quit never fires this.
    var onSurfacesClosed: (([UUID]) -> Void)? {
        didSet { registry.onSurfacesRemoved = onSurfacesClosed }
    }

    /// Every surface ID across all projects/tabs/panes (for orphan diffing).
    var allSurfaceIDs: [UUID] {
        workspace.projects.flatMap { project in
            project.tabList.trees.flatMap { tree in
                tree.layout.surfaces.map(\.id)
            }
        }
    }

    /// Called to reload configuration from disk (⇧⌘,).
    var onReloadConfig: (() -> Void)?

    // MARK: - View lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Terminal surfaces must adopt the active palette before the first pane
        // is created (see SurfaceRegistry.terminalTheme).
        registry.terminalTheme = QTheme.current.terminalTheme()
        registry.terminalConfiguration = ghosttyConfiguration
        view.layer?.backgroundColor = QTheme.current.bg1Color.cgColor
        setupSidebarAndContent()
        setupTabBar()
        setupStatusBar()
        rebuildSurfaceNodeView()
        refreshSidebar()
        refreshStatusBar()

        // Refresh the tab bar whenever any live surface reports a title or
        // working-directory change so the active tab's name stays current.
        registry.onTitleChange = { [weak self] id in
            self?.persistTitle(for: id)
            self?.refreshTabBar()
            self?.refreshSidebar()
            // The subscription fires once when the pane's surface pair is
            // created, which makes this a reliable per-pane one-shot hook.
            self?.nudgeAfterReattach(id)
        }

        startAgentEventWatcher()
        startForegroundPolling()
    }

    /// Polls which known agent CLI is in the foreground of each preserved
    /// pane's zmx session. Cheap (one `zmx list` + one `ps` every few seconds,
    /// off-main); a no-op when zmx isn't installed or no sessions exist.
    private func startForegroundPolling() {
        pollForegroundAgents()
        foregroundPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.pollForegroundAgents()
        }
    }

    private func pollForegroundAgents() {
        // Skip ticks while quertty is in the background — identities can't
        // change visibly and the zmx/ps calls are pure overhead; the next
        // tick after reactivation catches up.
        guard NSApp.isActive else { return }
        guard let zmx = ZmxRunner.locate() else { return }
        let ids = allSurfaceIDs
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pids = ZmxRunner.sessionPIDs(zmxPath: zmx)
            guard !pids.isEmpty, let ps = ZmxRunner.psSnapshot() else { return }
            var commands: [UUID: String] = [:]
            for id in ids {
                guard let pid = pids[SessionPersistence.sessionName(for: id)],
                      let command = ForegroundProcess.command(forSessionPID: pid, psOutput: ps)
                else { continue }
                commands[id] = command
            }
            DispatchQueue.main.async {
                guard let self, self.foregroundBySurface != commands else { return }
                self.foregroundBySurface = commands
                self.refreshTabBar()
                self.refreshSidebar()
            }
        }
    }

    /// Tab-name identity for a pane: the probed foreground agent first, then
    /// the hook-detected agent (covers panes without a zmx session).
    private func agentIdentity(for surface: Surface?) -> AgentKind? {
        guard let surface else { return nil }
        if let command = foregroundBySurface[surface.id],
           let descriptor = AgentRegistry.match(command: command) {
            return descriptor.kind
        }
        return agentDetector.state(for: surface.id).kind
    }

    /// The agent's display name for tab text, lowercased ("claude code").
    private func agentDisplayName(for surface: Surface?) -> String? {
        guard let surface, let kind = agentIdentity(for: surface) else { return nil }
        let descriptor = AgentRegistry.all.first { $0.kind == kind }
        return (descriptor?.displayName ?? kind.displayName).lowercased()
    }

    /// The pane's tool logo: agent brand mark (bundled SVG or glyph), or a
    /// bundled logo for other tools (vim, nano). Nil → the tab shows the name
    /// prefix / emitted title instead.
    private func agentIcon(for surface: Surface?) -> NSImage? {
        guard let surface else { return nil }
        if let kind = agentIdentity(for: surface) { return AgentIcons.icon(for: kind) }
        if let command = foregroundBySurface[surface.id] { return AgentIcons.icon(forTool: command) }
        return nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Give focus to whichever terminal the PaneTree considers focused.
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
        // Observe first-responder changes on the window to track which pane the
        // user clicks into.  `AppTerminalView.onFocusChange` is `internal` to
        // GhosttyTerminal, so KVO on `NSWindow.firstResponder` is the only
        // cross-module way to detect the transition.
        startObservingFirstResponder()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        firstResponderObservation = nil
    }

    // MARK: - Layout restoration

    /// Replaces the current `WorkspaceModel` with the given one.
    ///
    /// Called by `AppDelegate` before the view appears so the restored layout
    /// is rendered on first draw.
    func restore(workspace model: WorkspaceModel) {
        workspace = model
    }

    /// A snapshot of the current `WorkspaceModel` suitable for persistence.
    var currentWorkspace: WorkspaceModel {
        workspace
    }

    // MARK: - Theme

    /// Re-applies the active `QTheme` to every surface at runtime (called when
    /// the color scheme changes, e.g. the OS toggled appearance in system mode).
    ///
    /// Static layer colors are updated directly; the tab bar, sidebar, and pane
    /// tree are rebuilt so their cells re-read the theme. The registry recolors
    /// live terminals in place, so PTY sessions are preserved.
    func applyTheme() {
        view.layer?.backgroundColor = QTheme.current.bg1Color.cgColor
        contentContainer?.layer?.backgroundColor = QTheme.current.bg1Color.cgColor
        separatorView?.layer?.backgroundColor = QTheme.current.borderColor.cgColor
        tabBarView?.applyTheme()
        sidebarView?.applyTheme()
        statusBarView?.applyTheme()
        registry.reapplyTerminalTheme(QTheme.current.terminalTheme())
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    // MARK: - Sidebar + content layout setup

    private func setupSidebarAndContent() {
        let sidebar = SidebarView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = QTheme.current.bg1Color.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sidebar)
        view.addSubview(container)

        // Sidebar left edge, fixed width (handoff: 264pt), full height. The
        // leading constraint is retained so ⌘B can slide it off-screen.
        let sidebarLeading = sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        self.sidebarLeadingConstraint = sidebarLeading
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarLeading,
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth),

            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Add a thin themed separator line between sidebar and content.
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = QTheme.current.borderColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
        self.separatorView = separator

        // Wire sidebar callbacks.
        sidebar.onSelectProject = { [weak self] index in
            self?.selectProject(at: index)
        }

        sidebar.onSelectTab = { [weak self] projectIndex, tabIndex in
            guard let self else { return }
            self.workspace.select(index: projectIndex)
            self.workspace.activeTabList.select(index: tabIndex)
            self.refreshTabBar()
            self.rebuildSurfaceNodeView()
            self.refreshSidebar()
            if let focused = self.focusedTerminalView() {
                self.view.window?.makeFirstResponder(focused)
            }
        }

        sidebar.onTogglePin = { [weak self] index in
            guard let self else { return }
            self.workspace.togglePin(at: index)
            self.refreshSidebar()
            self.onWorkspaceDidChange?()
        }

        sidebar.onAddProject = { [weak self] in
            self?.presentAddProjectPanel()
        }

        self.sidebarView = sidebar
        self.contentContainer = container
    }

    // MARK: - Tab bar setup

    private func setupTabBar() {
        guard let container = contentContainer else { return }

        let tabBar = TabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabBar)

        tabBar.onSelect = { [weak self] index in
            self?.selectTab(at: index)
        }
        tabBar.onNewTab = { [weak self] in
            self?.newTab(nil)
        }
        tabBar.onRenameTab = { [weak self] index, newName in
            self?.renameTab(at: index, to: newName)
        }
        tabBar.currentManualTitle = { [weak self] index in
            let trees = self?.workspace.activeTabList.trees ?? []
            return trees.indices.contains(index) ? trees[index].manualTitle : nil
        }
        tabBar.onCloseTab = { [weak self] index in
            self?.closeTab(atIndex: index)
        }
        tabBar.onToggleSidebar = { [weak self] in
            self?.toggleSidebar(nil)
        }

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),
        ])

        self.tabBarView = tabBar
        refreshTabBar()
    }

    // MARK: - Status bar setup

    private func setupStatusBar() {
        guard let container = contentContainer else { return }

        let statusBar = StatusBarView()
        statusBar.onSelectAppearance = { [weak self] mode in self?.onSetAppearance?(mode) }
        statusBar.onSelectScheme = { [weak self] scheme in self?.onSelectScheme?(scheme) }
        container.addSubview(statusBar)
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
        self.statusBarView = statusBar
    }

    /// Syncs the status bar with the focused pane's working directory and the
    /// active scheme / shell / libghostty version.
    /// Syncs the status bar with the CURRENTLY FOCUSED pane (works across tabs
    /// and splits — the focused leaf of the active tab's tree).
    func refreshStatusBar() {
        guard let statusBar = statusBarView else { return }
        let focused = paneTree.focusedSurface
        let rawCwd = focused.flatMap { registry.workingDirectory(for: $0) }
            ?? focused?.workingDir
            ?? NSHomeDirectory()
        let cwd = Self.normalizedPath(rawCwd)
        let shell = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            .lastPathComponent
        statusBar.update(
            cwd: Self.abbreviatingHome(cwd),
            appearance: appearanceModeName?() ?? "System",
            scheme: QTheme.scheme.displayName,
            shell: shell,
            ghostty: "libghostty \(Self.libghosttyVersion)"
        )
        scheduleGitProbe(for: cwd, surfaceID: paneTree.focusedSurfaceID)
    }

    /// Debounced, off-main `git` probe for the focused pane's directory. The
    /// result is applied only if the SAME pane is still focused — guarding by
    /// surface identity (not directory string), so a shell that reports its cwd
    /// in a slightly different form than the pane's seed dir doesn't get dropped.
    private func scheduleGitProbe(for directory: String, surfaceID: UUID?) {
        gitProbeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let status = GitStatusProbe.probe(directory: directory)
            DispatchQueue.main.async {
                guard let self, self.paneTree.focusedSurfaceID == surfaceID else { return }
                self.statusBarView?.updateGit(status)
            }
        }
        gitProbeWork = work
        gitQueue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Strips a `file://` URL wrapper (some shells report OSC 7 as a URL) to a
    /// plain filesystem path; returns the input unchanged otherwise.
    private static func normalizedPath(_ raw: String) -> String {
        if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL {
            return url.path
        }
        return raw
    }

    /// Replaces a leading home-directory prefix with `~`.
    private static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - AI agent detection

    /// Location of the hook event sink that harness hooks append to.
    private static var agentEventsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".quertty", isDirectory: true)
            .appendingPathComponent("agent-events.jsonl")
    }

    private func startAgentEventWatcher() {
        let url = Self.agentEventsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let watcher = AgentEventWatcher(url: url) { [weak self] events in
            self?.handleAgentEvents(events)
        }
        watcher.start()
        agentEventWatcher = watcher
        replayAgentEvents(from: url)
    }

    /// One-shot startup replay of the existing event log, so agents that were
    /// already running before launch (panes reattached to preserved sessions)
    /// regain their status dots and tab names. The watcher itself tails only
    /// new lines. Reads a bounded tail of the log off-main; a duplicate of an
    /// event the watcher also delivers is harmless (same-state reduce).
    private func replayAgentEvents(from url: URL) {
        let maxReplayBytes = 256 * 1024
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            let tail = data.count > maxReplayBytes ? data.suffix(maxReplayBytes) : data
            guard let text = String(data: tail, encoding: .utf8) else { return }
            let events = AgentEventReplay.liveEvents(fromJSONL: text)
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { self?.handleAgentEvents(events) }
        }
    }

    /// Routes hook events to the sessions (surfaces) whose working directory
    /// matches the event's `cwd`, then refreshes the status dots.
    private func handleAgentEvents(_ events: [AgentEvent]) {
        let now = Date().timeIntervalSince1970
        var changed = false
        for event in events {
            let target = Self.normalizedPath(event.cwd)
            for project in workspace.projects {
                for tree in project.tabList.trees {
                    for surface in tree.layout.surfaces {
                        let cwd = registry.workingDirectory(for: surface).map(Self.normalizedPath)
                            ?? Self.normalizedPath(surface.workingDir)
                        if cwd == target {
                            agentDetector.apply(event: event, session: surface.id, now: now)
                            changed = true
                        }
                    }
                }
            }
        }
        if changed {
            refreshSidebar()
            refreshTabBar()
        }
    }

    // MARK: - Sidebar collapse

    /// Slides the sidebar off-screen (or back) with ⌘B; the content area follows.
    @objc func toggleSidebar(_ sender: Any?) {
        guard let leading = sidebarLeadingConstraint else { return }
        sidebarCollapsed.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            leading.animator().constant = sidebarCollapsed ? -sidebarWidth : 0
            separatorView?.animator().alphaValue = sidebarCollapsed ? 0 : 1
        }
    }

    // MARK: - Command palette

    /// Opens the ⌘K command palette, or closes it if already open.
    @objc func toggleCommandPalette(_ sender: Any?) {
        if commandPaletteView != nil {
            dismissCommandPalette()
        } else {
            presentCommandPalette()
        }
    }

    private func presentCommandPalette() {
        guard commandPaletteView == nil else { return }
        let palette = CommandPaletteView(
            commands: buildCommands(),
            onClose: { [weak self] in self?.dismissCommandPalette() }
        )
        view.addSubview(palette)
        NSLayoutConstraint.activate([
            palette.topAnchor.constraint(equalTo: view.topAnchor),
            palette.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            palette.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            palette.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        commandPaletteView = palette
    }

    private func dismissCommandPalette() {
        commandPaletteView?.removeFromSuperview()
        commandPaletteView = nil
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    /// The palette's command set, mapped to the controller's existing actions.
    private func buildCommands() -> [PaletteCommand] {
        let base: [PaletteCommand] = [
            PaletteCommand(glyph: "+", label: "New Tab", kbd: "⌘T") { [weak self] in self?.newTab(nil) },
            PaletteCommand(glyph: "▮", label: "Split Pane Right", kbd: "⌘D") { [weak self] in self?.splitVertical(nil) },
            PaletteCommand(glyph: "▬", label: "Split Pane Down", kbd: "⇧⌘D") { [weak self] in self?.splitHorizontal(nil) },
            PaletteCommand(glyph: "×", label: "Close Pane", kbd: "⌘W") { [weak self] in self?.closePane(nil) },
            PaletteCommand(glyph: "⊗", label: "Close Tab", kbd: "⇧⌘W") { [weak self] in self?.closeTab(nil) },
            PaletteCommand(glyph: "→", label: "Next Tab", kbd: "⌘}") { [weak self] in self?.selectNextTab(nil) },
            PaletteCommand(glyph: "←", label: "Previous Tab", kbd: "⌘{") { [weak self] in self?.selectPreviousTab(nil) },
            PaletteCommand(glyph: "★", label: "Pin / Unpin Current Project", kbd: "") { [weak self] in self?.togglePinActiveProject() },
            PaletteCommand(glyph: "＋", label: "Add Project…", kbd: "⌘O") { [weak self] in self?.addProject(nil) },
            PaletteCommand(glyph: "⛶", label: "Toggle Sidebar", kbd: "⌘B") { [weak self] in self?.toggleSidebar(nil) },
            PaletteCommand(glyph: "◐", label: "Cycle Color Scheme", kbd: "⇧⌘T") { [weak self] in self?.onCycleScheme?() },
            PaletteCommand(glyph: "◑", label: "Cycle Appearance", kbd: "⇧⌘A") { [weak self] in self?.onCycleAppearance?() },
            PaletteCommand(glyph: "◑", label: "Appearance: System", kbd: "") { [weak self] in self?.onSetAppearance?(.system) },
            PaletteCommand(glyph: "●", label: "Appearance: Dark", kbd: "") { [weak self] in self?.onSetAppearance?(.dark) },
            PaletteCommand(glyph: "○", label: "Appearance: Light", kbd: "") { [weak self] in self?.onSetAppearance?(.light) },
            PaletteCommand(glyph: "↻", label: "Reload Configuration", kbd: "⇧⌘,") { [weak self] in self?.onReloadConfig?() },
        ]
        // Jump to any project (focuses its active pane).
        let projectCommands = workspace.projects.enumerated().map { index, project in
            PaletteCommand(glyph: "◆", label: "Go to Project: \(project.name)", kbd: "") { [weak self] in
                self?.selectProject(at: index)
            }
        }

        // Scheme picks are scoped to the current axis, so they never flip dark↔light.
        let scoped = QTheme.current.isDark ? QColorScheme.darkSchemes : QColorScheme.lightSchemes
        let schemeCommands = scoped.map { scheme in
            PaletteCommand(glyph: "◐", label: "Scheme: \(scheme.displayName)", kbd: "") { [weak self] in
                self?.onSelectScheme?(scheme)
            }
        }

        return base + projectCommands + schemeCommands
    }

    // MARK: - Control socket (quertty CLI)

    /// Snapshot of the whole workspace for `quertty status` / target resolution.
    func statusSnapshot() -> StatusSnapshot {
        let projects = workspace.projects.enumerated().map { pIdx, project -> StatusSnapshot.Project in
            let isActiveProject = pIdx == workspace.activeIndex
            let tabs = project.tabList.trees.enumerated().map { tIdx, tree -> StatusSnapshot.Tab in
                let isActiveTab = isActiveProject && tIdx == project.tabList.activeIndex
                let panes = tree.layout.surfaces.map { surface -> StatusSnapshot.Pane in
                    StatusSnapshot.Pane(
                        id: SessionPersistence.shortID(for: surface.id),
                        title: registry.title(for: surface) ?? surface.lastTitle,
                        cwd: registry.workingDirectory(for: surface) ?? surface.workingDir,
                        tool: foregroundBySurface[surface.id],
                        agentStatus: agentDetector.state(for: surface.id).status?.rawValue,
                        isFocused: isActiveTab && surface.id == tree.focusedSurfaceID
                    )
                }
                let title = TabTitle.display(
                    manualTitle: tree.manualTitle,
                    agentName: agentDisplayName(for: tree.focusedSurface),
                    focusedSurfaceTitle: tree.focusedSurface.flatMap { registry.title(for: $0) ?? $0.lastTitle },
                    workingDir: tree.focusedSurface?.workingDir,
                    index: tIdx
                )
                return StatusSnapshot.Tab(title: title, isActive: isActiveTab, panes: panes)
            }
            return StatusSnapshot.Project(name: project.name, isActive: isActiveProject, tabs: tabs)
        }
        return StatusSnapshot(projects: projects)
    }

    /// Injects text/keys into the targeted pane (CLI `send`). Returns an error
    /// message, or nil on success.
    func sendInput(target: PaneSelector, text: String?, enter: Bool, keys: [String]) -> String? {
        do {
            let pane = try target.resolve(in: statusSnapshot().panes)
            guard let surface = surface(withShortID: pane.id) else {
                return "pane \(pane.id) is not live"
            }
            var payload = text ?? ""
            for key in keys {
                guard let sequence = KeyNotation.encode(key) else { return "unknown key \"\(key)\"" }
                payload += sequence
            }
            if enter { payload += "\r" }
            guard !payload.isEmpty else { return "nothing to send" }
            guard registry.sendText(payload, to: surface) else {
                return "pane \(pane.id) has no live terminal yet — focus its tab first"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Opens a new tab (CLI `new-tab`) in the named project (case-insensitive,
    /// nil → active project), makes it visible so its pane spawns, and returns
    /// the new pane's short id — or an error message.
    func openNewTab(inProject name: String?) -> Result<String, ControlError> {
        if let name {
            guard let index = workspace.projects.firstIndex(where: {
                $0.name.lowercased() == name.lowercased()
            }) else {
                return .failure(.noSuchPane("no project named \"\(name)\""))
            }
            if index != workspace.activeIndex { selectProject(at: index) }
        }
        newTab(nil)
        guard let surface = workspace.activeTabList.activeTree.focusedSurface
                ?? workspace.activeTabList.activeTree.layout.surfaces.first else {
            return .failure(.noSuchPane("tab created but no pane found"))
        }
        onWorkspaceDidChange?()
        return .success(SessionPersistence.shortID(for: surface.id))
    }

    /// Closes the targeted pane (CLI `close`): the pane collapses into its
    /// split; a tab's last pane — or `wholeTab` — closes the tab. Selects the
    /// owning project/tab first so the standard close paths (and their zmx
    /// session cleanup) apply. Returns an error message, or nil on success.
    func closePane(target: PaneSelector, wholeTab: Bool) -> String? {
        do {
            let pane = try target.resolve(in: statusSnapshot().panes)
            guard let location = locate(shortID: pane.id) else { return "pane \(pane.id) not found" }
            if location.projectIndex != workspace.activeIndex {
                selectProject(at: location.projectIndex)
            }
            let tabList = workspace.activeTabList
            if tabList.activeIndex != location.tabIndex {
                tabList.select(index: location.tabIndex)
            }
            let isLastPaneInTab = tabList.activeTree.layout.surfaces.count == 1
            if wholeTab || isLastPaneInTab {
                guard tabList.trees.count > 1 else {
                    return "cannot close the project's only tab"
                }
                closeTab(atIndex: location.tabIndex)
            } else {
                closePane(surfaceID: location.surfaceID)
                // Same reasoning as closeTab: prune misses never-spawned panes.
                onSurfacesClosed?([location.surfaceID])
            }
            refreshTabBar()
            refreshSidebar()
            onWorkspaceDidChange?()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func locate(shortID: String) -> (projectIndex: Int, tabIndex: Int, surfaceID: UUID)? {
        for pIdx in workspace.projects.indices {
            let trees = workspace.projects[pIdx].tabList.trees
            for tIdx in trees.indices {
                if let surface = trees[tIdx].layout.surfaces.first(where: {
                    SessionPersistence.shortID(for: $0.id) == shortID
                }) {
                    return (pIdx, tIdx, surface.id)
                }
            }
        }
        return nil
    }

    private func surface(withShortID shortID: String) -> Surface? {
        for project in workspace.projects {
            for tree in project.tabList.trees {
                if let surface = tree.layout.surfaces.first(where: {
                    SessionPersistence.shortID(for: $0.id) == shortID
                }) {
                    return surface
                }
            }
        }
        return nil
    }

    /// Surfaces already given their post-reattach repaint nudge.
    private var nudgedSurfaces: Set<UUID> = []

    /// One-shot repaint nudge for preserved panes. A zmx reattach replays the
    /// screen contents, but a running TUI paints only deltas on top of what it
    /// believes is on screen — the pane stays half-drawn until a size change
    /// forces a full redraw (user-confirmed: resizing fixes it). Shortly after
    /// the pane appears, shrink it by about a cell row and restore it, so the
    /// program gets SIGWINCH and repaints.
    private func nudgeAfterReattach(_ surfaceID: UUID) {
        guard sessionCommandProvider != nil, !nudgedSurfaces.contains(surfaceID) else { return }
        nudgedSurfaces.insert(surfaceID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let surface = self.surface(with: surfaceID) else { return }
            let view = self.registry.terminalView(for: surface)
            let original = view.frame.size
            guard original.height > 40 else { return }
            view.setFrameSize(NSSize(width: original.width, height: original.height - 20))
            DispatchQueue.main.async { view.setFrameSize(original) }
        }
    }

    /// The model surface with `id`, wherever it lives in the workspace.
    private func surface(with id: UUID) -> Surface? {
        for project in workspace.projects {
            for tree in project.tabList.trees {
                if let surface = tree.layout.surfaces.first(where: { $0.id == id }) {
                    return surface
                }
            }
        }
        return nil
    }

    /// Writes the live terminal title through to the persisted model, so tab
    /// names survive relaunch (a zmx reattach doesn't re-emit the title escape
    /// sequence). No save is scheduled — the debounced structural autosaves and
    /// the quit-time save carry it to disk.
    private func persistTitle(for surfaceID: UUID) {
        for project in workspace.projects {
            let surfaces = project.tabList.trees.flatMap { $0.layout.surfaces }
            guard let surface = surfaces.first(where: { $0.id == surfaceID }) else { continue }
            guard let title = registry.title(for: surface), !title.isEmpty,
                  title != surface.lastTitle else { return }
            project.tabList.updateSurface(surfaceID) { $0.lastTitle = title }
            return
        }
    }

    private func togglePinActiveProject() {
        workspace.togglePin(at: workspace.activeIndex)
        refreshSidebar()
        onWorkspaceDidChange?()
    }

    /// Syncs the tab bar UI state with the active project's TabList.
    ///
    /// For each tab, computes its display title via `TabTitle.display` using:
    /// - the tab's manual title (if set),
    /// - the live terminal title of the tab's focused surface (from the registry),
    /// - the live working directory of that surface (registry first, then the
    ///   static `Surface.workingDir` as a fallback),
    /// - and a positional fallback ("Tab N").
    func refreshTabBar() {
        let tabList = workspace.activeTabList
        var icons: [NSImage?] = []
        let titles: [String] = tabList.trees.indices.map { idx in
            let tree = tabList.trees[idx]
            let focusedSurface = tree.focusedSurface
            let surfaceTitle = focusedSurface.flatMap { registry.title(for: $0) ?? $0.lastTitle }
            let workingDir = focusedSurface.flatMap { registry.workingDirectory(for: $0) }
                ?? focusedSurface?.workingDir
            // A bundled logo replaces the name prefix; otherwise the name is
            // woven into the text ("claude code: <emitted title>").
            let icon = agentIcon(for: focusedSurface)
            icons.append(icon)
            let agentName = icon == nil ? agentDisplayName(for: focusedSurface) : nil
            return TabTitle.display(
                manualTitle: tree.manualTitle,
                agentName: agentName,
                focusedSurfaceTitle: surfaceTitle,
                workingDir: workingDir,
                index: idx
            )
        }
        tabBarView?.update(titles: titles, icons: icons, selectedIndex: tabList.activeIndex)
        // The status bar tracks the same focused-pane / active-tab state.
        refreshStatusBar()
    }

    /// Syncs the sidebar UI state with the workspace.
    func refreshSidebar() {
        let sidebarProjects: [SidebarProject] = workspace.projects.map { project in
            let trees = project.tabList.trees
            // Agent status per tab (from the tab's focused surface).
            let statuses: [AgentStatus?] = trees.map { tree in
                tree.focusedSurface.flatMap { agentDetector.state(for: $0.id).status }
            }
            let rollup = statuses.compactMap { $0 }.max { Self.severity($0) < Self.severity($1) }

            // Only provide tab titles when there are 2+ tabs (single-tab projects are plain rows).
            let tabTitles: [String]
            let tabStatuses: [AgentStatus?]
            var tabIcons: [NSImage?] = []
            if trees.count >= 2 {
                tabTitles = trees.indices.map { idx in
                    let tree = trees[idx]
                    let focusedSurface = tree.focusedSurface
                    let surfaceTitle = focusedSurface.flatMap { registry.title(for: $0) ?? $0.lastTitle }
                    let workingDir = focusedSurface.flatMap { registry.workingDirectory(for: $0) }
                        ?? focusedSurface?.workingDir
                    // Same rule as the tab bar: a logo replaces the name prefix.
                    let icon = agentIcon(for: focusedSurface)
                    tabIcons.append(icon)
                    let agentName = icon == nil ? agentDisplayName(for: focusedSurface) : nil
                    return TabTitle.display(
                        manualTitle: tree.manualTitle,
                        agentName: agentName,
                        focusedSurfaceTitle: surfaceTitle,
                        workingDir: workingDir,
                        index: idx
                    )
                }
                tabStatuses = statuses
            } else {
                tabTitles = []
                tabStatuses = []
            }
            return SidebarProject(
                name: project.name,
                isPinned: project.isPinned,
                tabTitles: tabTitles,
                tabStatuses: tabStatuses,
                tabIcons: tabIcons,
                status: rollup
            )
        }
        sidebarView?.update(
            projects: sidebarProjects,
            activeProject: workspace.activeIndex,
            activeTab: workspace.activeTabList.activeIndex
        )
    }

    /// Severity ranking for rolling up multiple tab statuses to a project glyph.
    private static func severity(_ status: AgentStatus) -> Int {
        switch status {
        case .needsAttention: return 3
        case .running:        return 2
        case .idle:           return 1
        }
    }

    // MARK: - Add Project via NSOpenPanel

    /// Presents an NSOpenPanel to choose a directory, then adds it as a new project.
    @objc func addProject(_ sender: Any?) {
        presentAddProjectPanel()
    }

    private func presentAddProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a directory to add as a project"

        guard let window = view.window else {
            // Fallback: run modally if no window yet.
            if panel.runModal() == .OK, let url = panel.url {
                addProjectFromURL(url)
            }
            return
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addProjectFromURL(url)
        }
    }

    private func addProjectFromURL(_ url: URL) {
        workspace.addProject(name: url.lastPathComponent, rootPath: url.path)
        refreshTabBar()
        rebuildSurfaceNodeView()
        refreshSidebar()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    // MARK: - Tab actions (responder-chain targets)

    /// Open a new tab and focus its single fresh pane.  Key equivalent: ⌘T.
    @objc func newTab(_ sender: Any?) {
        workspace.activeTabList.newTab()
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    /// Close the active tab.  No-op if it is the only tab.  Key equivalent: ⇧⌘W.
    @objc func closeTab(_ sender: Any?) {
        closeTab(atIndex: workspace.activeTabList.activeIndex)
    }

    /// Close the tab at an explicit index (called by the tab bar × button).
    /// No-op if it is the only tab.
    func closeTab(atIndex index: Int) {
        let tabList = workspace.activeTabList
        guard tabList.trees.indices.contains(index) else { return }
        let closingSurfaces = tabList.trees[index].layout.surfaces.map(\.id)
        let countBefore = tabList.trees.count
        tabList.closeTab(at: index)
        guard tabList.trees.count != countBefore else { return }   // only tab — no-op
        // Registry pruning only reports panes that actually spawned; report the
        // closed surfaces explicitly so never-spawned panes' zmx sessions are
        // killed too (a duplicate kill of a live pair is harmless).
        onSurfacesClosed?(closingSurfaces)
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    /// Switch to the next tab, wrapping.  Key equivalent: ⌘}.
    @objc func selectNextTab(_ sender: Any?) {
        workspace.activeTabList.selectNext()
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    /// Switch to the previous tab, wrapping.  Key equivalent: ⌘{.
    @objc func selectPreviousTab(_ sender: Any?) {
        workspace.activeTabList.selectPrevious()
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    // MARK: - Tab rename

    /// Applies a manual title to the tab at `index`.  An empty / whitespace-only
    /// `name` clears `manualTitle`, reverting the tab to its auto-computed name.
    private func renameTab(at index: Int, to name: String) {
        let tabList = workspace.activeTabList
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabList.setManualTitle(trimmed.isEmpty ? nil : trimmed, at: index)
        refreshTabBar()
        refreshSidebar()
        onWorkspaceDidChange?()
    }

    // MARK: - Private helper

    private func selectTab(at index: Int) {
        workspace.activeTabList.select(index: index)
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    /// Reapplies ghostty config overrides to all live panes (called on reload).
    func reloadGhosttyConfiguration(_ config: TerminalConfiguration?) {
        ghosttyConfiguration = config
        registry.reapplyTerminalConfiguration(config)
    }

    /// Switches to the project at `index` and focuses its active pane.
    func selectProject(at index: Int) {
        workspace.select(index: index)
        refreshTabBar()
        rebuildSurfaceNodeView()
        refreshSidebar()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    // MARK: - First-responder observation

    /// Starts (or restarts) KVO on `window.firstResponder`.
    ///
    /// When the first responder changes we walk its superview chain looking for
    /// a terminal view we recognise from the registry.  Finding one means the
    /// user clicked into that pane, so we update `paneTree.focusedSurfaceID`
    /// and redraw the focus highlights.
    private func startObservingFirstResponder() {
        guard let window = view.window else { return }
        firstResponderObservation = window.observe(
            \.firstResponder,
            options: [.new]
        ) { [weak self] _, _ in
            // observe is called on whatever thread AppKit uses; bounce to main.
            DispatchQueue.main.async {
                self?.handleFirstResponderChange()
            }
        }
    }

    private func handleFirstResponderChange() {
        guard let responder = view.window?.firstResponder as? NSView else { return }
        // Walk the superview chain of the new first responder to find which
        // registry view it belongs to (the terminal view itself, or a child of it).
        if let surfaceID = registry.surfaceID(containing: responder) {
            focusChanged(surfaceID: surfaceID)
        }
    }

    // MARK: - Tree rendering

    /// Replaces the root content view with a freshly-built `SurfaceNodeView`
    /// derived from `paneTree.layout.root`.
    ///
    /// After building, prunes the registry to the UNION of surface IDs across
    /// ALL projects' ALL tabs — background tabs and projects keep their live
    /// PTY sessions alive.
    ///
    /// Declared `internal` so the `PaneActions` extension (same module) can call it.
    func rebuildSurfaceNodeView() {
        guard let container = contentContainer else { return }

        rootContentView?.removeFromSuperview()

        let showsClose = paneTree.layout.surfaces.count > 1
        let newRoot = SurfaceNodeView(
            node: paneTree.layout.root,
            registry: registry,
            focusedSurfaceID: paneTree.focusedSurfaceID,
            showsClose: showsClose,
            onClose: { [weak self] id in self?.closePane(surfaceID: id) }
        )
        newRoot.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(newRoot)

        // Pin below the tab bar (28 pt), or to the top if there is no tab bar yet.
        let topGuide: NSLayoutYAxisAnchor
        if let tabBar = tabBarView {
            topGuide = tabBar.bottomAnchor
        } else {
            topGuide = container.topAnchor
        }

        // Sit above the status bar (if present), else to the container bottom.
        let bottomGuide = statusBarView?.topAnchor ?? container.bottomAnchor

        NSLayoutConstraint.activate([
            newRoot.topAnchor.constraint(equalTo: topGuide),
            newRoot.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            newRoot.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            newRoot.bottomAnchor.constraint(equalTo: bottomGuide),
        ])
        rootContentView = newRoot

        // Prune to the union of ALL projects' ALL tabs' surfaces so background
        // sessions survive project switches as well as tab switches.
        let allIDs = Set(
            workspace.projects.flatMap { project in
                project.tabList.trees.flatMap { tree in
                    tree.layout.surfaces.map(\.id)
                }
            }
        )
        registry.prune(keeping: allIDs)

        // Any structural change (tab add/close, split/close, project add, switch)
        // funnels through here — autosave so disk reflects the current layout.
        onWorkspaceDidChange?()
    }

    // MARK: - Helpers

    /// Returns the `NSView` for the currently focused surface, if any.
    /// Declared `internal` so the `PaneActions` extension (same module) can call it.
    func focusedTerminalView() -> NSView? {
        guard let surface = paneTree.focusedSurface else { return nil }
        return registry.terminalView(for: surface)
    }

    // MARK: - Focus tracking

    /// Called whenever the KVO observer detects a first-responder change to a
    /// known terminal view.
    ///
    /// Updates `paneTree.focusedSurfaceID` and re-renders so the focus
    /// highlight moves to the newly focused leaf.
    private func focusChanged(surfaceID: UUID) {
        guard paneTree.focusedSurfaceID != surfaceID else { return }
        paneTree.focus(surfaceID)
        // Update the highlight IN PLACE — do NOT rebuild. Rebuilding re-parents the
        // live terminal views, which resigns the clicked pane's first responder so
        // it never actually takes keyboard focus (highlight without an active cursor).
        rootContentView?.updateFocus(paneTree.focusedSurfaceID)
        // The active tab's name follows its focused pane's title.
        refreshTabBar()
        refreshSidebar()
    }
}
