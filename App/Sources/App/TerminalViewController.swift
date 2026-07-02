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
        registry.onTitleChange = { [weak self] _ in
            self?.refreshTabBar()
            self?.refreshSidebar()
        }

        startAgentEventWatcher()
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
        let titles: [String] = tabList.trees.indices.map { idx in
            let tree = tabList.trees[idx]
            let focusedSurface = tree.focusedSurface
            let surfaceTitle = focusedSurface.flatMap { registry.title(for: $0) }
            let workingDir = focusedSurface.flatMap { registry.workingDirectory(for: $0) }
                ?? focusedSurface?.workingDir
            return TabTitle.display(
                manualTitle: tree.manualTitle,
                focusedSurfaceTitle: surfaceTitle,
                workingDir: workingDir,
                index: idx
            )
        }
        tabBarView?.update(titles: titles, selectedIndex: tabList.activeIndex)
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
            if trees.count >= 2 {
                tabTitles = trees.indices.map { idx in
                    let tree = trees[idx]
                    let focusedSurface = tree.focusedSurface
                    let surfaceTitle = focusedSurface.flatMap { registry.title(for: $0) }
                    let workingDir = focusedSurface.flatMap { registry.workingDirectory(for: $0) }
                        ?? focusedSurface?.workingDir
                    return TabTitle.display(
                        manualTitle: tree.manualTitle,
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
        let tabList = workspace.activeTabList
        tabList.closeTab(at: tabList.activeIndex)
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    /// Close the tab at an explicit index (called by the tab bar × button).
    /// No-op if it is the only tab.
    func closeTab(atIndex index: Int) {
        let tabList = workspace.activeTabList
        tabList.closeTab(at: index)
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
