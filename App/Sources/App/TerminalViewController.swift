import AppKit
import GhosttyTerminal
import ZettyCore
import ZettyGhostty

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
    /// Read by AppDelegate (per-project settings resolution at spawn time and
    /// on settings edits); mutation stays in this class.
    private(set) var workspace = WorkspaceModel()

    /// The logical pane tree for the ACTIVE tab in the ACTIVE project.  Mutate
    /// this, then call `rebuildSurfaceNodeView()`.  Declared `internal` so the
    /// `PaneActions` extension (same module) can write it.
    var paneTree: PaneTree {
        get { workspace.activeTabList.activeTree }
        set { workspace.activeTabList.activeTree = newValue }
    }

    /// The currently installed root content view (a `SurfaceNodeView`).
    private var rootContentView: SurfaceNodeView?
    /// The dormant-project placeholder, shown instead of `rootContentView` when
    /// the active project is hibernated.
    private var placeholderView: NSView?

    /// The tab bar strip shown above the pane area.
    private var tabBarView: TabBarView?

    /// The project sidebar shown on the left.
    private var sidebarView: SidebarView?

    /// The bottom status strip (cwd · scheme · shell · libghostty version).
    private var statusBarView: StatusBarView?

    /// The command palette overlay, when open.
    private var commandPaletteView: CommandPaletteView?

    /// The prefix-key layer's event monitor + engine (nil until the owner
    /// calls `installKeyBindings`).
    private var keyInterceptor: KeyInterceptor?

    /// Copy-mode driver for the focused pane (selection-as-cursor mechanics).
    let copyMode = CopyModeController()

    /// Per-session AI-agent state, driven by harness-hook events.
    private let agentDetector = AgentDetector()
    /// Watches the hook event sink (`~/.zetty/agent-events.jsonl`).
    private var agentEventWatcher: AgentEventWatcher?

    /// Foreground command per preserved pane, from the zmx/ps probe. This is
    /// the identity used for tab logos/names; hook events only drive the
    /// status dots. Known agents get brand logos; other tools (vim, nano)
    /// get one when we bundle it.
    private var foregroundBySurface: [UUID: String] = [:]
    private var foregroundPollTimer: Timer?

    /// Broadcast (synchronized input) is per-project and Off by default. The
    /// active project's scope is read/written through these (AppDelegate owns
    /// the persisted per-project store).
    var broadcastScopeProvider: ((ProjectRuntime) -> BroadcastScope)?
    var onSetBroadcastScope: ((ProjectRuntime, BroadcastScope) -> Void)?
    var broadcastScope: BroadcastScope { broadcastScopeProvider?(workspace.activeProject) ?? .off }
    var isBroadcasting: Bool { broadcastScope.isActive }

    /// The pinned libghostty-spm version (no runtime version API is exposed).
    /// Keep in sync with `Project.swift`'s package requirement.
    static let libghosttyVersion = "1.2.7"

    /// Build identity for the status bar: the marketing version (`CFBundle
    /// ShortVersionString`) for clean builds — every release DMG and any clean
    /// local build. A dirty (WIP) build instead shows the short git commit with
    /// a `*` suffix (stamped by the "Stamp build commit" phase) for precise
    /// identity; `dev` when neither is available.
    static let buildStamp: String = {
        let info = Bundle.main.infoDictionary
        let commit = (info?["ZettyBuildCommit"] as? String) ?? ""
        // A dirty (WIP) build shows its commit for precise identity; a clean
        // build — every release DMG, and any clean local build — shows the
        // marketing version instead.
        if commit.hasSuffix("*") { return commit }
        if let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        return commit.isEmpty ? "dev" : commit
    }()

    /// Background queue + debounce for `git` probes feeding the status bar.
    private let gitQueue = DispatchQueue(label: "co.webteractive.zetty.git", qos: .utility)
    private var gitProbeWork: DispatchWorkItem?

    /// The container that wraps the tab-bar + pane area (right side of the split).
    private var contentContainer: NSView?

    /// The 1pt divider between the sidebar and content (retained so it can be
    /// recolored when the scheme changes).
    private var separatorView: NSView?

    /// Sidebar geometry. The edge constraint pins the sidebar to its window
    /// side (leading or trailing per `sidebarPosition`) and is animated to
    /// collapse it; the width constraint is user-draggable within
    /// `SidebarMetrics` bounds. All position-dependent constraints are kept so
    /// a runtime position change can re-pin in place.
    private var sidebarWidth: CGFloat = SidebarMetrics.defaultWidth
    private var sidebarEdgeConstraint: NSLayoutConstraint?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarLayoutConstraints: [NSLayoutConstraint] = []
    private var sidebarResizeHandle: SidebarResizeHandle?
    private var sidebarCollapsed = false

    /// Which window side the sidebar sits on (config `sidebar-position`).
    /// Settable before the view loads; changing it afterwards re-pins live.
    var sidebarPosition: SidebarPosition = .left {
        didSet {
            guard isViewLoaded, oldValue != sidebarPosition else { return }
            applySidebarLayout()
        }
    }

    /// Read/unread bookkeeping for the attention bell (visiting a pane marks
    /// its current attention episode read; session-scoped, not persisted).
    private let attentionInbox = AttentionInbox()

    /// KVO token for observing `window.firstResponder`.
    private var firstResponderObservation: NSKeyValueObservation?

    /// Called after any change that affects persisted workspace state (tab
    /// add/close, split/close, project add/pin, rename). The owner (AppDelegate)
    /// uses this to autosave, so the on-disk workspace always reflects the
    /// current arrangement — surviving crashes/force-quits, not just clean quit.
    var onWorkspaceDidChange: (() -> Void)?

    /// Called to switch to a specific color scheme (owner applies + persists).
    var onSelectScheme: ((ZColorScheme) -> Void)?

    /// Called to cycle to the next color scheme (⌘⇧T).
    var onCycleScheme: (() -> Void)?
    /// The status-bar "update available" pill was clicked.
    var onUpdatePillClicked: (() -> Void)?
    /// The status-bar "reinstall CLI" pill was clicked.
    var onCLIReinstallClicked: (() -> Void)?

    /// Shows/hides the status-bar update pill (driven by AppDelegate's checker).
    func showUpdate(_ update: AvailableUpdate?) {
        statusBarView?.setUpdate(update)
    }

    /// Reflects the CLI symlink status in the status bar (pill when stale).
    func showCLIStatus(_ status: CLIStatus) {
        statusBarView?.setCLIStatus(status)
    }

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
    /// (session preservation: `zmx attach zetty-<id>`). Affects NEW panes only.
    var sessionCommandProvider: ((UUID) -> String?)? {
        didSet {
            registry.surfaceCommand = sessionCommandProvider.map { provider in
                { surface in provider(surface.id) }
            }
        }
    }

    /// When set, new panes get these environment variables (per-project env
    /// from settings). Affects NEW panes only — a preserved zmx session
    /// captures its env at first creation.
    var surfaceEnvironmentProvider: ((UUID) -> [String: String]?)? {
        didSet {
            registry.surfaceEnvironment = surfaceEnvironmentProvider.map { provider in
                { surface in provider(surface.id) }
            }
        }
    }

    /// Called with surface IDs removed by an explicit close (pane/tab/project),
    /// so their persistent sessions can be killed. App quit never fires this.
    var onSurfacesClosed: (([UUID]) -> Void)? {
        didSet {
            let handler = onSurfacesClosed
            registry.onSurfacesRemoved = { ids in
                ids.forEach(PaneCwdStore.remove)   // drop each closed pane's cwd file
                handler?(ids)
            }
        }
    }

    /// Every surface ID across all projects/tabs/panes (for orphan diffing).
    /// Hibernated projects are excluded so their surfaces are pruned (torn down)
    /// and never spawn until woken.
    var allSurfaceIDs: [UUID] {
        workspace.projects.filter { !$0.isHibernated }.flatMap { project in
            project.tabList.trees.flatMap { tree in
                tree.layout.surfaces.map(\.id)
            }
        }
    }

    /// Called to reload configuration from disk (⇧⌘,).
    var onReloadConfig: (() -> Void)?

    /// Called to open the Settings window (sidebar gear; ⌘, equivalent).
    var onOpenSettings: (() -> Void)?

    // MARK: - View lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Terminal surfaces must adopt the active palette before the first pane
        // is created (see SurfaceRegistry.terminalTheme).
        registry.terminalTheme = ZTheme.current.terminalTheme()
        registry.terminalConfiguration = ghosttyConfiguration
        view.layer?.backgroundColor = ZTheme.current.bg1Color.cgColor
        setupSidebarAndContent()
        setupTabBar()
        setupStatusBar()
        rebuildSurfaceNodeView()
        refreshSidebar()
        refreshStatusBar()

        // Refresh the tab bar whenever any live surface reports a title or
        // working-directory change so the active tab's name stays current.
        registry.onTitleChange = { [weak self] id in
            guard let self else { return }
            // A fresh live title supersedes any staleness mark.
            if let surface = self.surface(with: id), self.registry.title(for: surface) != nil {
                self.staleTitleSurfaces.remove(id)
            }
            self.persistTitle(for: id)
            self.refreshTabBar()
            self.refreshSidebar()
            // The subscription fires once when the pane's surface pair is
            // created, which makes this a reliable per-pane one-shot hook.
            self.nudgeAfterReattach(id)
            self.injectStartupCommandIfPending(id)
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
        // Skip ticks while Zetty is in the background — identities can't
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
                guard let pid = pids[SessionPersistence.sessionName(for: id)] else { continue }
                // "" = probed and found an idle shell / nothing running. The
                // distinction matters: a probed-idle pane must NOT fall back
                // to hook-detected identity (hooks are cwd-fuzzy and sticky —
                // a claude that once ran in the same cwd would wrongly brand
                // an idle pane with its logo).
                commands[id] = ForegroundProcess.command(forSessionPID: pid, psOutput: ps) ?? ""
            }
            DispatchQueue.main.async {
                guard let self, self.foregroundBySurface != commands else { return }
                let previous = self.foregroundBySurface
                self.foregroundBySurface = commands
                // A pane that just went idle keeps whatever title its tool
                // last emitted (ghostty never resets titles) — mark it stale
                // so the tab falls back to the directory until the terminal
                // emits a fresh title.
                for (id, command) in commands where command.isEmpty && previous[id] != "" {
                    self.markTitleStale(id)
                }
                self.refreshTabBar()
                self.refreshSidebar()
            }
        }
    }

    /// Tab-name identity for a pane. The probe is authoritative for any pane
    /// it examined ("" = probed, idle — no identity); the hook-detected agent
    /// only covers panes the probe can't see (no zmx session).
    private func agentIdentity(for surface: Surface?) -> AgentKind? {
        guard let surface else { return nil }
        if let command = foregroundBySurface[surface.id] {
            guard !command.isEmpty else { return nil }
            return AgentRegistry.match(command: command)?.kind
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
        if let command = foregroundBySurface[surface.id], !command.isEmpty {
            return AgentIcons.icon(forTool: command)
        }
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

    /// Seeds the sidebar's restored state. Call before the view loads.
    func restoreSidebar(collapsed: Bool, width: Double) {
        sidebarCollapsed = collapsed
        sidebarWidth = SidebarMetrics.clampWidth(width)
    }

    /// The sidebar state to persist alongside the workspace.
    var sidebarStateForPersistence: (collapsed: Bool, width: Double) {
        (sidebarCollapsed, Double(sidebarWidth))
    }

    // MARK: - Theme

    /// Re-applies the active `ZTheme` to every surface at runtime (called when
    /// the color scheme changes, e.g. the OS toggled appearance in system mode).
    ///
    /// Static layer colors are updated directly; the tab bar, sidebar, and pane
    /// tree are rebuilt so their cells re-read the theme. The registry recolors
    /// live terminals in place, so PTY sessions are preserved.
    func applyTheme() {
        view.layer?.backgroundColor = ZTheme.current.bg1Color.cgColor
        contentContainer?.layer?.backgroundColor = ZTheme.current.bg1Color.cgColor
        separatorView?.layer?.backgroundColor = ZTheme.current.borderColor.cgColor
        tabBarView?.applyTheme()
        sidebarView?.applyTheme()
        statusBarView?.applyTheme()
        registry.reapplyTerminalTheme(ZTheme.current.terminalTheme())
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
        container.layer?.backgroundColor = ZTheme.current.bg1Color.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sidebar)
        view.addSubview(container)

        // Thin themed separator line between sidebar and content.
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = ZTheme.current.borderColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)
        self.separatorView = separator

        // Invisible grab zone straddling the separator; dragging it resizes
        // the sidebar within SidebarMetrics bounds, double-click resets.
        let handle = SidebarResizeHandle()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.onDragBegan = { [weak self] in self?.sidebarDragStartWidth = self?.sidebarWidth ?? 0 }
        handle.onDrag = { [weak self] totalDelta in self?.resizeSidebar(totalDelta: totalDelta) }
        handle.onDragEnded = { [weak self] in self?.onWorkspaceDidChange?() }
        handle.onReset = { [weak self] in self?.resetSidebarWidth() }
        view.addSubview(handle)
        self.sidebarResizeHandle = handle

        self.sidebarView = sidebar
        self.contentContainer = container
        applySidebarLayout()

        // Wire sidebar callbacks.
        sidebar.onSelectProject = { [weak self] index in
            guard let self, self.workspace.projects.indices.contains(index) else { return }
            // Selecting a hibernated project SHOWS it (a dormant placeholder with
            // a Wake button) — it stays hibernated until the wake is intentional.
            self.selectProject(at: index)
        }
        sidebar.onToggleHibernate = { [weak self] index in self?.toggleHibernation(at: index) }

        sidebar.onShowBellMenu = { [weak self] anchor in self?.showAttentionMenu(from: anchor) }
        sidebar.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        sidebar.onSelectTab = { [weak self] projectIndex, tabIndex in
            guard let self, self.workspace.projects.indices.contains(projectIndex) else { return }
            self.workspace.select(index: projectIndex)
            // Same activation hook as selectProject(at:) — a tab click can
            // switch projects too (per-project theme must follow).
            self.onActiveProjectChanged?()
            self.workspace.activeTabList.select(index: tabIndex)
            self.refreshTabBar()
            self.rebuildSurfaceNodeView()
            self.refreshSidebar()
            if let focused = self.focusedTerminalView() {
                self.view.window?.makeFirstResponder(focused)
            }
        }

        sidebar.onMoveTab = { [weak self] projectIndex, from, to in
            guard let self, self.workspace.projects.indices.contains(projectIndex) else { return }
            self.workspace.projects[projectIndex].tabList.moveTab(from: from, to: to)
            self.refreshTabBar()
            self.refreshSidebar()
            self.onWorkspaceDidChange?()
        }

        sidebar.onMoveProject = { [weak self] from, to in
            guard let self else { return }
            self.workspace.moveProject(from: from, to: to)
            self.refreshSidebar()
            self.onWorkspaceDidChange?()
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

        sidebar.onRemoveProject = { [weak self] index in
            self?.confirmRemoveProject(at: index)
        }

        sidebar.onCloneProject = { [weak self] index in
            self?.promptCloneProject(at: index)
        }

        sidebar.onRenameProject = { [weak self] index in
            guard let self, self.workspace.projects.indices.contains(index) else { return }
            self.onRenameProject?(self.workspace.projects[index])
        }

        sidebar.onOpenProjectSettings = { [weak self] index in
            guard let self, self.workspace.projects.indices.contains(index) else { return }
            self.onOpenProjectSettings?(self.workspace.projects[index])
        }
    }

    /// (Re)pins the sidebar, separator, resize handle, and content container
    /// for the current `sidebarPosition`, preserving the collapsed state.
    /// Safe to call repeatedly — deactivates the previous constraint set.
    private func applySidebarLayout() {
        guard let sidebar = sidebarView, let container = contentContainer,
              let separator = separatorView, let handle = sidebarResizeHandle else { return }

        NSLayoutConstraint.deactivate(sidebarLayoutConstraints)

        let width = sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth)
        sidebarWidthConstraint = width

        var constraints: [NSLayoutConstraint] = [
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            width,
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            handle.topAnchor.constraint(equalTo: view.topAnchor),
            handle.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 8),
            handle.centerXAnchor.constraint(equalTo: separator.centerXAnchor),
        ]

        let edge: NSLayoutConstraint
        switch sidebarPosition {
        case .left:
            edge = sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            constraints += [
                container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            ]
        case .right:
            edge = sidebar.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            constraints += [
                container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            ]
        }
        edge.constant = sidebarCollapsed ? collapsedEdgeConstant : 0
        constraints.append(edge)
        sidebarEdgeConstraint = edge

        sidebarLayoutConstraints = constraints
        NSLayoutConstraint.activate(constraints)

        handle.dragDirectionSign = (sidebarPosition == .left) ? 1 : -1
        handle.isHidden = sidebarCollapsed
        separator.alphaValue = sidebarCollapsed ? 0 : 1
        // The tab bar's toggle button hugs the sidebar's edge.
        tabBarView?.sidebarPosition = sidebarPosition
    }

    /// The edge-constraint constant that slides the sidebar fully off-screen.
    private var collapsedEdgeConstant: CGFloat {
        sidebarPosition == .left ? -sidebarWidth : sidebarWidth
    }

    /// Width captured when a handle drag begins, so each drag event applies
    /// its TOTAL delta to the start width (no drift or clamp hysteresis).
    private var sidebarDragStartWidth: CGFloat = 0

    /// Live width change from a handle drag (delta already sign-corrected).
    private func resizeSidebar(totalDelta: CGFloat) {
        let clamped = CGFloat(SidebarMetrics.clampWidth(Double(sidebarDragStartWidth + totalDelta)))
        guard clamped != sidebarWidth else { return }
        sidebarWidth = clamped
        sidebarWidthConstraint?.constant = clamped
    }

    /// Double-click on the handle: back to the default width.
    private func resetSidebarWidth() {
        sidebarWidth = SidebarMetrics.defaultWidth
        sidebarWidthConstraint?.constant = sidebarWidth
        onWorkspaceDidChange?()
    }

    // MARK: - Tab bar setup

    private func setupTabBar() {
        guard let container = contentContainer else { return }

        let tabBar = TabBarView()
        tabBar.sidebarPosition = sidebarPosition
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
        tabBar.onMoveTab = { [weak self] source, destination in
            guard let self else { return }
            self.workspace.activeTabList.moveTab(from: source, to: destination)
            // The grabbed tab becomes the active one on drop (browser-style).
            self.workspace.activeTabList.select(index: destination)
            self.refreshTabBar()
            self.refreshSidebar()
            self.rebuildSurfaceNodeView()
            if let focused = self.focusedTerminalView() {
                self.view.window?.makeFirstResponder(focused)
            }
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
        statusBar.onShowEditorMenu = { [weak self] anchor in self?.showEditorMenu(from: anchor) }
        statusBar.onUpdateClicked = { [weak self] in self?.onUpdatePillClicked?() }
        statusBar.onBroadcastClicked = { [weak self] in self?.cycleBroadcast() }
        statusBar.onCLIReinstallClicked = { [weak self] in self?.onCLIReinstallClicked?() }
        container.addSubview(statusBar)
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 30),
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
        let rawCwd = focused.flatMap { PaneCwdStore.read($0.id) }
            ?? focused.flatMap { registry.workingDirectory(for: $0) }
            ?? focused?.workingDir
            ?? NSHomeDirectory()
        let cwd = Self.normalizedPath(rawCwd)
        let shell = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            .lastPathComponent
        statusBar.update(
            cwd: Self.abbreviatingHome(cwd),
            appearance: appearanceModeName?() ?? "System",
            scheme: ZTheme.scheme.displayName,
            shell: shell,
            zetty: "v\(Self.buildStamp)",
            ghostty: "libghostty \(Self.libghosttyVersion)"
        )
        statusBar.setZoomed(paneTree.zoomedSurfaceID != nil)
        statusBar.setBroadcasting(broadcastScope)
        scheduleGitProbe(for: cwd, surfaceID: paneTree.focusedSurfaceID)
    }

    /// Fans raw bytes out to every pane in the active broadcast target set
    /// (including the focused pane, so all panes receive identical input).
    /// Targets are recomputed per call, so panes opened/closed mid-broadcast
    /// are handled; background/unspawned panes silently no-op. Not broadcasting
    /// → nothing happens.
    func broadcast(_ text: String) {
        guard broadcastScope.isActive else { return }
        let all = workspace.projects.flatMap { $0.tabList.trees.flatMap { $0.layout.surfaces } }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projectSurfaces = workspace.activeProject.tabList.trees.flatMap { $0.layout.surfaces }
        let targets = Broadcast.targets(
            scope: broadcastScope,
            currentTabSurfaces: paneTree.layout.surfaces.map(\.id),
            currentProjectSurfaces: projectSurfaces.map(\.id),
            allSurfaces: all.map(\.id),
            hasAgent: { self.agentIdentity(for: byID[$0]) != nil })
        for id in targets {
            if let surface = byID[id] { _ = registry.sendText(text, to: surface) }
        }
    }

    // MARK: - Prefix-key layer

    /// Creates the copy-mode controller wiring and installs the app-local key
    /// monitor. Called once by the owner (AppDelegate) after launch.
    func installKeyBindings(_ configuration: KeyBindingConfiguration) {
        copyMode.terminalView = { [weak self] id in self?.registry.appTerminalView(for: id) }
        copyMode.gridMetrics = { [weak self] id in self?.registry.viewState(for: id)?.surfaceSize }
        copyMode.captureLines = { id, rows in
            guard let zmx = ZmxRunner.locate(),
                  let history = ZmxRunner.history(session: SessionPersistence.sessionName(for: id), zmxPath: zmx)
            else { return nil }
            let all = history.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return Array(all.suffix(rows))
        }
        let interceptor = KeyInterceptor(configuration: configuration, viewController: self)
        interceptor.install()
        keyInterceptor = interceptor
    }

    /// Applies reloaded binding tables (⇧⌘,) and drops any armed/copy state.
    func applyKeyBindings(_ configuration: KeyBindingConfiguration) {
        exitCopyModeIfActive()
        keyInterceptor?.apply(configuration: configuration)
        statusBarView?.setKeyMode(.normal)
    }

    /// Updates the status-bar mode chip (PREFIX / COPY / hidden).
    func keyModeDidChange(_ mode: KeyMode) {
        statusBarView?.setKeyMode(mode)
    }

    /// Starts copy mode on the focused pane. False when it has no live view.
    func enterCopyMode() -> Bool {
        guard let id = paneTree.focusedSurfaceID else { return false }
        return copyMode.enter(surfaceID: id)
    }

    /// Ends copy mode from an external cause (layout change, focus change,
    /// config reload) — clears selection, engine state, and the chip.
    func exitCopyModeIfActive() {
        guard copyMode.activeSurfaceID != nil else { return }
        copyMode.exit()
        keyInterceptor?.engine.exitCopyMode()
        statusBarView?.setKeyMode(.normal)
    }

    /// Ghostty-native paste into the focused pane (prefix + ]).
    func pasteIntoFocusedPane() {
        guard let id = paneTree.focusedSurfaceID,
              let view = registry.appTerminalView(for: id) else { return }
        view.performBindingAction("paste_from_clipboard")
    }

    /// Jump to tab N (1-based, prefix + 1…9). Out-of-range is a no-op.
    func selectTab(number: Int) {
        let index = number - 1
        guard workspace.activeTabList.trees.indices.contains(index) else { return }
        selectTab(at: index)
    }

    /// Opens the inline rename editor on the active tab (prefix + ,).
    func beginRenameActiveTab() {
        tabBarView?.beginRenameProgrammatically(at: workspace.activeTabList.activeIndex)
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
            .appendingPathComponent(".zetty", isDirectory: true)
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
            // Replayed state must not ring bells — it's potentially stale.
            DispatchQueue.main.async { self?.handleAgentEvents(events, notify: false) }
        }
    }

    /// Routes hook events to the sessions (surfaces) whose working directory
    /// matches the event's `cwd`, then refreshes the status dots.
    /// Fired when a pane's agent transitions INTO needs-attention (never
    /// during the startup replay). Payload: pane surface, agent kind, and the
    /// owning project (per-project notification overrides are resolved by the
    /// receiver).
    var onAgentNeedsAttention: ((Surface, AgentKind, ProjectRuntime) -> Void)?

    /// Per-project dock-badge gate (nil → everything counts). The in-app
    /// bell/inbox always sees every unread pane — only the Dock badge is
    /// filtered (a suppressed project shouldn't nag from the Dock).
    var badgeEligible: ((ProjectRuntime) -> Bool)?

    /// Resolves a project's identity (color + custom glyph) from its
    /// settings; nil closure or nil fields → default rendering.
    var projectIdentity: ((ProjectRuntime) -> (color: NSColor?, glyph: String?))?

    /// Resolves a project's agent-chooser config (enabled agents + whether the
    /// new-pane prompt is on) from per-project settings.
    var agentsProvider: ((ProjectRuntime) -> AgentSpawnConfig)?

    /// Opens Project Settings on the Agents tab (from the chooser's "Manage
    /// agents…" button).
    var onOpenAgentSettings: ((ProjectRuntime) -> Void)?

    /// If the active project has the chooser enabled AND ≥1 enabled agent,
    /// present a modal chooser BEFORE spawning; `onProceed(command)` runs for a
    /// picked agent, `onProceed(nil)` for a standard session, and neither for
    /// Cancel (no tab/pane created). Otherwise spawns immediately as a standard
    /// session.
    func chooseAgentThenSpawn(_ onProceed: @escaping (String?) -> Void) {
        guard workspace.projects.indices.contains(workspace.activeIndex) else {
            onProceed(nil); return
        }
        let project = workspace.projects[workspace.activeIndex]
        let config = agentsProvider?(project) ?? .disabled
        let agents = config.agents
        guard config.promptOnNewPane, !agents.isEmpty, let window = view.window else {
            onProceed(nil); return
        }
        AgentChooserSheet.present(agents: agents, on: window) { [weak self] outcome in
            switch outcome {
            case .agent(let command): onProceed(command)   // launch chosen agent
            case .standard:           onProceed(nil)         // standard session
            case .manage:             self?.onOpenAgentSettings?(project)
            case .cancel:             break                  // nothing created
            }
        }
    }

    /// Opens a new tab, optionally injecting a startup command once its pane
    /// spawns (used by the agent chooser). Shared by the interactive path.
    func performNewTab(startupCommand: String?) {
        workspace.activeTabList.newTab()
        if let startupCommand, let id = workspace.activeTabList.activeTree.focusedSurface?.id {
            pendingStartupCommands[id] = startupCommand
        }
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    /// Splits the focused pane, optionally injecting a startup command once the
    /// new pane spawns (used by the agent chooser). Shared by the split actions.
    func performSplit(direction: SplitDirection, startupCommand: String?) {
        let workingDir = paneTree.focusedSurface?.workingDir ?? NSHomeDirectory()
        let newSurface = Surface(workingDir: workingDir)
        if let startupCommand { pendingStartupCommands[newSurface.id] = startupCommand }
        paneTree.splitFocused(direction: direction, newSurface: newSurface)
        rebuildAndFocus()
    }

    /// Sidebar "Rename…" — payload is the project runtime (the receiver
    /// resolves and persists the name override).
    var onRenameProject: ((ProjectRuntime) -> Void)?

    /// Sidebar "Project Settings…" — payload is the project runtime.
    var onOpenProjectSettings: ((ProjectRuntime) -> Void)?

    /// Fired when the ACTIVE project changes (select, add, remove) — the
    /// receiver re-applies per-project theme overrides.
    var onActiveProjectChanged: (() -> Void)?

    /// Resolves a project's layout template (repo `.zetty/project.json`
    /// first, then the global default); nil → seed the usual single pane.
    var layoutTemplateProvider: ((ProjectRuntime) -> LayoutTemplate?)?

    /// Startup commands awaiting injection into freshly spawned panes —
    /// populated ONLY by template application, and in-memory only, so a
    /// relaunch can never re-run a command into a preserved session.
    private var pendingStartupCommands: [UUID: String] = [:]

    /// Injects a template pane's startup command shortly after its view
    /// spawns (the delay lets the shell — or the scrollback-restore wrapper's
    /// attach — start reading the pty before the text arrives).
    private func injectStartupCommandIfPending(_ surfaceID: UUID) {
        guard let command = pendingStartupCommands.removeValue(forKey: surfaceID) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let surface = self.surface(with: surfaceID) else { return }
            _ = self.registry.sendText(command + "\r", to: surface)
        }
    }

    /// Replaces `project`'s tabs with its resolved layout template (panes
    /// spawn lazily via the usual rebuild; replaced panes' sessions are
    /// killed like a close). Returns false when no template resolves.
    @discardableResult
    func applyLayoutTemplate(to project: ProjectRuntime) -> Bool {
        guard let template = layoutTemplateProvider?(project),
              let built = template.tabList(rootPath: project.rootPath) else { return false }
        let closingSurfaces = project.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }
        project.tabList.replaceTrees(from: built.tabList)
        pendingStartupCommands.merge(built.commands) { _, new in new }
        onSurfacesClosed?(closingSurfaces)
        refreshTabBar()
        rebuildSurfaceNodeView()
        refreshSidebar()
        return true
    }

    /// Captures `project`'s live arrangement as its repo-file template.
    /// Returns the captured template (the caller persists it).
    func captureLayoutTemplate(for project: ProjectRuntime) -> LayoutTemplate {
        LayoutTemplate.capture(from: project.tabList, rootPath: project.rootPath)
    }

    /// Fired whenever the number of attention panes changes (Dock badge).
    var onAttentionCountChanged: ((Int) -> Void)?

    private func handleAgentEvents(_ events: [AgentEvent], notify: Bool = true) {
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
                            let previous = agentDetector.state(for: surface.id).status
                            let next = agentDetector.apply(event: event, session: surface.id, now: now)
                            changed = true
                            if notify, next.status == .needsAttention, previous != .needsAttention,
                               let kind = next.kind {
                                onAgentNeedsAttention?(surface, kind, project)
                            }
                        }
                    }
                }
            }
        }
        if changed {
            refreshSidebar()
            refreshTabBar()
            publishAttentionCount()
            // An episode that starts in the pane the user is already looking
            // at is read on arrival — visiting marks read, and they're there.
            if NSApp.isActive, let focused = paneTree.focusedSurfaceID {
                acknowledgeAttention(for: focused)
            }
        }
    }

    /// Recomputes the UNREAD attention count and fires the callback — always,
    /// so a config reload can re-apply Dock-badge gating even when the count
    /// itself is unchanged (re-setting the same badge is free). Syncs the
    /// inbox first so ended attention episodes drop their read marks. The
    /// bell shows every unread pane; the Dock badge only badge-eligible ones.
    func publishAttentionCount() {
        let needsAttention = Set(
            workspace.projects
                .flatMap { $0.tabList.trees.flatMap { $0.layout.surfaces } }
                .filter { agentDetector.state(for: $0.id).status == .needsAttention }
                .map(\.id)
        )
        attentionInbox.update(needsAttention: needsAttention)
        sidebarView?.updateBell(count: attentionInbox.unreadCount)

        let unread = attentionInbox.unread
        let badgeCount = workspace.projects
            .filter { badgeEligible?($0) ?? true }
            .flatMap { $0.tabList.trees.flatMap { $0.layout.surfaces } }
            .filter { unread.contains($0.id) }
            .count
        onAttentionCountChanged?(badgeCount)
    }

    /// The bell's menu: every UNREAD needs-attention pane; selecting one jumps
    /// to it, and the visit marks it read. "Clear All" marks everything read
    /// without visiting. The bell is in-app-only — independent of the
    /// notification config toggles.
    private func showAttentionMenu(from anchor: NSView) {
        let menu = NSMenu()
        let unread = attentionInbox.unread
        for (pIdx, project) in workspace.projects.enumerated() {
            for (tIdx, tree) in project.tabList.trees.enumerated() {
                for surface in tree.layout.surfaces where unread.contains(surface.id) {
                    let kind = agentDetector.state(for: surface.id).kind
                    let name = kind?.displayName ?? "agent"
                    let item = NSMenuItem(
                        title: "\(name) — \(project.name)",
                        action: #selector(attentionPanePicked(_:)), keyEquivalent: ""
                    )
                    item.target = self
                    if let kind, let icon = AgentIcons.icon(for: kind) { item.image = icon }
                    item.representedObject = [pIdx, tIdx] as [Int]
                    menu.addItem(item)
                }
            }
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: "No unread notifications", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(
                title: "Clear All",
                action: #selector(clearAllNotifications(_:)), keyEquivalent: ""
            )
            clear.target = self
            menu.addItem(clear)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: anchor)
    }

    /// Fired when one pane's attention is marked read (visit), and when the
    /// user clears everything — the owner sweeps the matching macOS
    /// Notification Center items so they don't pile up after being seen.
    var onAttentionRead: ((UUID) -> Void)?
    var onAttentionReadAll: (() -> Void)?

    /// Marks every current attention episode read ("read all") — the bell
    /// empties and the Dock badge clears; the status dots stay truthful.
    @objc func clearAllNotifications(_ sender: Any?) {
        attentionInbox.acknowledgeAll()
        publishAttentionCount()
        onAttentionReadAll?()
    }

    /// Visiting a pane marks its current attention episode read.
    private func acknowledgeAttention(for surfaceID: UUID) {
        guard attentionInbox.unread.contains(surfaceID) else { return }
        attentionInbox.acknowledge(surfaceID)
        publishAttentionCount()
        onAttentionRead?(surfaceID)
    }

    @objc private func attentionPanePicked(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? [Int], location.count == 2 else { return }
        if location[0] != workspace.activeIndex { selectProject(at: location[0]) }
        let tabList = workspace.activeTabList
        if tabList.activeIndex != location[1] { selectTab(at: location[1]) }
    }

    // MARK: - Sidebar collapse

    /// Slides the sidebar off-screen (or back) with ⌘B; the content area follows.
    @objc func toggleSidebar(_ sender: Any?) {
        guard let edge = sidebarEdgeConstraint else { return }
        sidebarCollapsed.toggle()
        sidebarResizeHandle?.isHidden = sidebarCollapsed
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            edge.animator().constant = sidebarCollapsed ? collapsedEdgeConstant : 0
            separatorView?.animator().alphaValue = sidebarCollapsed ? 0 : 1
        }
        onWorkspaceDidChange?()
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
            PaletteCommand(glyph: "⇤", label: "Resize Pane Left", kbd: "⌥⌘←") { [weak self] in self?.resizePaneLeft(nil) },
            PaletteCommand(glyph: "⇥", label: "Resize Pane Right", kbd: "⌥⌘→") { [weak self] in self?.resizePaneRight(nil) },
            PaletteCommand(glyph: "⤒", label: "Resize Pane Up", kbd: "⌥⌘↑") { [weak self] in self?.resizePaneUp(nil) },
            PaletteCommand(glyph: "⤓", label: "Resize Pane Down", kbd: "⌥⌘↓") { [weak self] in self?.resizePaneDown(nil) },
            PaletteCommand(glyph: "×", label: "Close Pane", kbd: "⌘W") { [weak self] in self?.closePane(nil) },
            PaletteCommand(glyph: "↗", label: "Break Pane into Tab", kbd: "⌥⌘T") { [weak self] in self?.breakPaneIntoTab(nil) },
            PaletteCommand(glyph: "⊗", label: "Close Tab", kbd: "⇧⌘W") { [weak self] in self?.closeTab(nil) },
            PaletteCommand(glyph: "→", label: "Next Tab", kbd: "⌘}") { [weak self] in self?.selectNextTab(nil) },
            PaletteCommand(glyph: "←", label: "Previous Tab", kbd: "⌘{") { [weak self] in self?.selectPreviousTab(nil) },
            PaletteCommand(glyph: "★", label: "Pin / Unpin Current Project", kbd: "") { [weak self] in self?.togglePinActiveProject() },
            PaletteCommand(glyph: "＋", label: "Add Project…", kbd: "⌘O") { [weak self] in self?.addProject(nil) },
            PaletteCommand(glyph: "⎇", label: "Clone Current Project…", kbd: "") { [weak self] in
                guard let self else { return }
                self.promptCloneProject(at: self.workspace.activeIndex)
            },
            PaletteCommand(glyph: "⧉", label: "New Scratch Terminal", kbd: "⌃⌘N") { [weak self] in self?.newScratchTerminal() },
            PaletteCommand(glyph: "⌦", label: "Close All Scratch Terminals", kbd: "") { [weak self] in self?.closeAllScratchTerminals() },
            PaletteCommand(glyph: "☾", label: "Hibernate Current Project", kbd: "") { [weak self] in
                guard let self else { return }
                self.hibernateProject(self.workspace.activeProject)
            },
            PaletteCommand(glyph: "−", label: "Remove Current Project…", kbd: "") { [weak self] in self?.removeProject(nil) },
            PaletteCommand(glyph: "⛶", label: "Toggle Sidebar", kbd: "⌘B") { [weak self] in self?.toggleSidebar(nil) },
            PaletteCommand(glyph: "⇉", label: "Broadcast: Tab", kbd: "") { [weak self] in self?.setBroadcast(.currentTab) },
            PaletteCommand(glyph: "⇉", label: "Broadcast: Project", kbd: "") { [weak self] in self?.setBroadcast(.project) },
            PaletteCommand(glyph: "⇉", label: "Broadcast: Agents", kbd: "") { [weak self] in self?.setBroadcast(.agents) },
            PaletteCommand(glyph: "⇉", label: "Broadcast: Workspace", kbd: "") { [weak self] in self?.setBroadcast(.workspace) },
            PaletteCommand(glyph: "⇥", label: "Broadcast: Cycle Scope", kbd: "⇧⌘B") { [weak self] in self?.cycleBroadcast() },
            PaletteCommand(glyph: "○", label: "Broadcast: Off", kbd: "") { [weak self] in self?.setBroadcast(.off) },
            PaletteCommand(glyph: "◎", label: "Clear All Notifications", kbd: "") { [weak self] in self?.clearAllNotifications(nil) },
            PaletteCommand(glyph: "◐", label: "Cycle Color Scheme", kbd: "⇧⌘T") { [weak self] in self?.onCycleScheme?() },
            PaletteCommand(glyph: "◑", label: "Cycle Appearance", kbd: "⇧⌘A") { [weak self] in self?.onCycleAppearance?() },
            PaletteCommand(glyph: "◑", label: "Appearance: System", kbd: "") { [weak self] in self?.onSetAppearance?(.system) },
            PaletteCommand(glyph: "●", label: "Appearance: Dark", kbd: "") { [weak self] in self?.onSetAppearance?(.dark) },
            PaletteCommand(glyph: "○", label: "Appearance: Light", kbd: "") { [weak self] in self?.onSetAppearance?(.light) },
            PaletteCommand(glyph: "↻", label: "Reload Configuration", kbd: "⇧⌘,") { [weak self] in self?.onReloadConfig?() },
        ]
        // Jump to any project (focuses its active pane).
        let projectCommands = workspace.projects.enumerated().map { index, project in
            let hibernated = project.isHibernated
            return PaletteCommand(
                glyph: hibernated ? "☾" : "◆",
                label: hibernated ? "Wake Project: \(project.name)" : "Go to Project: \(project.name)",
                kbd: "") { [weak self] in
                    guard let self else { return }
                    if hibernated { self.wakeProject(project) } else { self.selectProject(at: index) }
                }
        }

        // Scheme picks are scoped to the current axis, so they never flip dark↔light.
        let scoped = ZTheme.current.isDark ? ZColorScheme.darkSchemes : ZColorScheme.lightSchemes
        let schemeCommands = scoped.map { scheme in
            PaletteCommand(glyph: "◐", label: "Scheme: \(scheme.displayName)", kbd: "") { [weak self] in
                self?.onSelectScheme?(scheme)
            }
        }

        return base + projectCommands + schemeCommands
    }

    // MARK: - Control socket (Zetty CLI)

    /// Snapshot of the whole workspace for `Zetty status` / target resolution.
    func statusSnapshot() -> StatusSnapshot {
        let projects = workspace.projects.enumerated().map { pIdx, project -> StatusSnapshot.Project in
            let isActiveProject = pIdx == workspace.activeIndex
            let tabs = project.tabList.trees.enumerated().map { tIdx, tree -> StatusSnapshot.Tab in
                let isActiveTab = isActiveProject && tIdx == project.tabList.activeIndex
                let panes = tree.layout.surfaces.map { surface -> StatusSnapshot.Pane in
                    StatusSnapshot.Pane(
                        id: SessionPersistence.shortID(for: surface.id),
                        title: displayTitle(for: surface),
                        cwd: PaneCwdStore.read(surface.id) ?? registry.workingDirectory(for: surface) ?? surface.workingDir,
                        tool: foregroundBySurface[surface.id].flatMap { $0.isEmpty ? nil : $0 },
                        agentStatus: agentDetector.state(for: surface.id).status?.rawValue,
                        isFocused: isActiveTab && surface.id == tree.focusedSurfaceID
                    )
                }
                let title = TabTitle.display(
                    manualTitle: tree.manualTitle,
                    agentName: agentDisplayName(for: tree.focusedSurface),
                    focusedSurfaceTitle: displayTitle(for: tree.focusedSurface),
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
    func openNewTab(inProject name: String?, focus: Bool = false) -> Result<String, ControlError> {
        let targetIndex: Int
        if let name {
            guard let idx = workspace.projects.firstIndex(where: {
                $0.name.lowercased() == name.lowercased()
            }) else {
                return .failure(.noSuchPane("no project named \"\(name)\""))
            }
            targetIndex = idx
        } else {
            targetIndex = workspace.activeIndex
        }
        let tabList = workspace.projects[targetIndex].tabList
        let newPaneID = tabList.newBackgroundTab()
        let newTabIndex = tabList.trees.count - 1

        if focus {
            tabList.select(index: newTabIndex)
            if targetIndex != workspace.activeIndex {
                selectProject(at: targetIndex)          // rebuilds + focuses the now-active tab
            } else {
                refreshTabBar()
                rebuildSurfaceNodeView()
                refreshSidebar()
                if let focused = focusedTerminalView() {
                    view.window?.makeFirstResponder(focused)
                }
            }
        } else {
            // Background: the tab exists and shows in the bar, but the visible
            // tab and keyboard focus are unchanged.
            refreshTabBar()
            refreshSidebar()
        }
        onWorkspaceDidChange?()
        return .success(SessionPersistence.shortID(for: newPaneID))
    }

    /// Opens a new **Home** tab running `command` as a one-shot startup command
    /// (used by the ssh:// URL handover). Wakes Home first if it is hibernated,
    /// switches to it if it is not active, and focuses the new tab. The command
    /// is injected via the usual `pendingStartupCommands` path once the pane
    /// spawns, so it works whether or not Home preserves sessions.
    func openSSHSession(command: String) {
        guard let homeIndex = workspace.projects.firstIndex(where: { $0.isHome }) else { return }
        let home = workspace.projects[homeIndex]

        let tabList = home.tabList
        let newPaneID = tabList.newBackgroundTab()
        tabList.select(index: tabList.trees.count - 1)
        pendingStartupCommands[newPaneID] = command

        if home.isHibernated {
            wakeProject(home)                     // selects + rebuilds → new pane spawns
        } else if homeIndex != workspace.activeIndex {
            selectProject(at: homeIndex)          // selects + rebuilds
        } else {
            refreshTabBar()
            rebuildSurfaceNodeView()
            refreshSidebar()
            if let focused = focusedTerminalView() {
                view.window?.makeFirstResponder(focused)
            }
        }
        onWorkspaceDidChange?()
    }

    /// Adds the directory at `path` as a new project (CLI `add-project`),
    /// makes it active so its first pane spawns, and returns that pane's
    /// short id — or an error message.
    func addProject(path: String, name: String?, focus: Bool = false) -> Result<String, ControlError> {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.protocolError("no such directory: \(root)"))
        }
        if let existing = workspace.projects.first(where: { $0.rootPath == root }) {
            return .failure(.protocolError("project \"\(existing.name)\" already uses \(root)"))
        }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let project = addProjectFromURL(
            URL(fileURLWithPath: root), name: (trimmed?.isEmpty ?? true) ? nil : trimmed, activate: focus)
        guard let surface = project.tabList.activeTree.focusedSurface
                ?? project.tabList.activeTree.layout.surfaces.first else {
            return .failure(.noSuchPane("project added but no pane found"))
        }
        return .success(SessionPersistence.shortID(for: surface.id))
    }

    // MARK: - Clone Project (copy-on-write fork)

    /// Plans a clone of the named project (nil → the active project). Main
    /// thread — reads workspace state and does FS existence checks only; the
    /// copy itself runs in `CloneRunner` off-main.
    func planClone(projectName: String?, cloneName: String?) -> Result<ClonePlan, ControlError> {
        let source: ProjectRuntime
        if let projectName {
            let matches = workspace.projects.filter {
                $0.name.lowercased() == projectName.lowercased()
            }
            guard let match = matches.first else {
                return .failure(.protocolError("no project named \"\(projectName)\""))
            }
            guard matches.count == 1 else {
                return .failure(.protocolError("\(matches.count) projects named \"\(projectName)\""))
            }
            source = match
        } else {
            source = workspace.activeProject
        }
        guard !source.isScratch else {
            return .failure(.protocolError("scratch terminals can't be cloned"))
        }
        guard !source.isHome else {
            return .failure(.protocolError("Home can't be cloned"))
        }
        guard source.cloneSource == nil else {
            return .failure(.protocolError("\"\(source.name)\" is already a clone — clone the original instead"))
        }
        // Bare clone names already taken for this source ("src/fork-1" → "fork-1").
        let taken = Set(workspace.clones(of: source).map {
            String($0.name.dropFirst(source.name.count + 1))
        })
        switch CloneSupport.plan(sourceName: source.name, sourceRootPath: source.rootPath,
                                 cloneName: cloneName, takenCloneNames: taken,
                                 home: NSHomeDirectory()) {
        case .failure(let error):
            return .failure(.protocolError(error.localizedDescription))
        case .success(let plan):
            guard !FileManager.default.fileExists(atPath: plan.targetPath) else {
                return .failure(.protocolError("a directory already exists at \(plan.targetPath)"))
            }
            return .success(plan)
        }
    }

    /// Registers a finished clone copy as a workspace project (main thread) and
    /// returns its first pane's short id. Background by default; `focus`
    /// switches to it and spawns its pane. Layout templates and startup commands
    /// deliberately do NOT apply — the clone carries the source's real files.
    func registerClone(plan: ClonePlan, outcome: CloneRunner.Outcome, focus: Bool) -> Result<String, ControlError> {
        let project = workspace.addCloneProject(
            name: plan.projectName, rootPath: plan.targetPath,
            cloneSource: plan.sourceRootPath, makeActive: focus)
        refreshTabBar()
        refreshSidebar()
        if focus {
            onActiveProjectChanged?()
            rebuildSurfaceNodeView()   // spawns the pane + autosaves
            if let focused = focusedTerminalView() {
                view.window?.makeFirstResponder(focused)
            }
        } else {
            onWorkspaceDidChange?()     // persist the added clone
        }
        if let branchError = outcome.branchError {
            presentGitInitWarning(
                "The clone was created, but branch setup (git switch -c \(plan.branchName)) failed:\n\(branchError)")
        } else if !outcome.usedCoW {
            // Spec: the fallback is labeled honestly — the user should know this
            // was a full byte copy (slow, real disk), not an instant CoW clone.
            presentGitInitWarning(
                "The volume doesn't support copy-on-write, so the clone is a full copy.")
        }
        guard let surface = project.tabList.activeTree.focusedSurface
                ?? project.tabList.activeTree.layout.surfaces.first else {
            return .failure(.noSuchPane("clone added but no pane found"))
        }
        return .success(SessionPersistence.shortID(for: surface.id))
    }

    /// Sheet asking for a clone name (pre-filled with the next free "fork-N"),
    /// then clones in the background and focuses the result. Interactive entry —
    /// agents use `zetty clone` instead.
    func promptCloneProject(at index: Int) {
        guard workspace.projects.indices.contains(index) else { return }
        let source = workspace.projects[index]
        guard !source.isScratch, !source.isHome, source.cloneSource == nil else { return }
        let taken = Set(workspace.clones(of: source).map {
            String($0.name.dropFirst(source.name.count + 1))
        })

        let alert = NSAlert()
        alert.messageText = "Clone \u{201c}\(source.name)\u{201d}"
        alert.informativeText = "Creates an instant copy-on-write copy under ~/.zetty/clones"
            + " on its own git branch. Everything comes along — untracked files, deps, caches."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = CloneSupport.defaultCloneName(existing: taken)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")

        let sourceID = source.id
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            // Re-resolve by identity — indices can shift while the sheet is up.
            guard let current = self.workspace.projects.first(where: { $0.id == sourceID }) else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            switch self.planClone(projectName: current.name, cloneName: name.isEmpty ? nil : name) {
            case .failure(let error):
                self.presentCloneError(error.localizedDescription)
            case .success(let plan):
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let result = CloneRunner.clone(plan)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch result {
                        case .failure(let failure):
                            self.presentCloneError(failure.message)
                        case .success(let outcome):
                            _ = self.registerClone(plan: plan, outcome: outcome, focus: true)
                        }
                    }
                }
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(alert.runModal())
        }
    }

    private func presentCloneError(_ text: String, title: String = "Clone failed") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    // MARK: - Create Project (new folder on disk)

    enum GitInitOutcome: Equatable {
        case notRequested
        case succeeded
        case failed(String)
    }

    /// Creates a new directory at `path` (which must not already exist) and,
    /// when `gitInit` is set, runs `git init` in it. Directory creation is a
    /// hard failure; a failed `git init` is soft (the folder still exists).
    func createProjectDirectory(atPath path: String, gitInit: Bool) -> Result<GitInitOutcome, ControlError> {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        if FileManager.default.fileExists(atPath: target) {
            return .failure(.protocolError("a file or folder already exists at \(target)"))
        }
        do {
            try FileManager.default.createDirectory(
                atPath: target, withIntermediateDirectories: false)
        } catch {
            return .failure(.protocolError("could not create \(target): \(error.localizedDescription)"))
        }
        guard gitInit else { return .success(.notRequested) }
        if let message = runGitInit(atPath: target) {
            return .success(.failed(message))
        }
        return .success(.succeeded)
    }

    /// Runs `git init` in `path`; returns an error message on failure, nil on success.
    private func runGitInit(atPath path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return text.isEmpty ? "git init exited \(process.terminationStatus)" : text
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Creates a new project folder then adds it (CLI `new-project`). Returns
    /// the first pane's short id. A failed `git init` is non-fatal: the project
    /// is still created and its pane id returned.
    func newProject(path: String, name: String?, gitInit: Bool, focus: Bool = false) -> Result<String, ControlError> {
        switch createProjectDirectory(atPath: path, gitInit: gitInit) {
        case .failure(let error):
            return .failure(error)
        case .success:
            return addProject(path: path, name: name, focus: focus)
        }
    }

    /// Outcome of planning a CLI `remove-project` (see `planRemoveProject`):
    /// either resolved immediately on main (an ordinary project is removed
    /// right there, or the request is invalid), or a clone that needs
    /// off-main git work before it can be removed — see
    /// `AppDelegate.startControlSocket`'s `.removeProject` case, which does
    /// that work on the socket queue so a slow `git fetch` can't beachball
    /// the app.
    enum RemoveProjectPlan {
        case failed(String)
        case completed
        case clonePending(cloneID: UUID, cloneRoot: String, sourceRoot: String)
    }

    /// Phase 1 of CLI `remove-project` (case-insensitive), main thread only:
    /// resolves + validates the target against workspace state. An ordinary
    /// project is removed here and now — closing all of its tabs/panes and
    /// ending their zmx sessions, no confirmation dialog (the CLI call IS the
    /// confirmation). A clone target defers its git work to phase 2/3 instead
    /// of running it here, off-main.
    func planRemoveProject(name: String, fetch: Bool, discard: Bool) -> RemoveProjectPlan {
        let matches = workspace.projects.enumerated().filter {
            $0.element.name.lowercased() == name.lowercased()
        }
        guard let match = matches.first else {
            return .failed("no project named \"\(name)\"")
        }
        guard matches.count == 1 else {
            return .failed("\(matches.count) projects named \"\(name)\" — remove it via the sidebar")
        }
        guard !match.element.isHome else {
            return .failed("Home can't be removed")
        }

        guard let sourceRoot = match.element.cloneSource else {
            // Ordinary project — the clone flags don't apply.
            guard !fetch, !discard else {
                return .failed("\"\(name)\" is not a clone — --fetch/--discard don't apply")
            }
            performRemoveProject(at: match.offset)
            return .completed
        }
        return .clonePending(cloneID: match.element.id, cloneRoot: match.element.rootPath,
                              sourceRoot: sourceRoot)
    }

    /// Phase 3 of CLI `remove-project` for a clone, main thread only: called
    /// after phase 2's off-main state/flag policy check has passed (and any
    /// requested fetch-back has succeeded). Re-resolves the clone BY ID —
    /// it may have moved or been removed entirely while phase 2 ran — then
    /// removes it and deletes its directory. Returns an error message, or
    /// nil on success.
    func completeRemoveClone(cloneID: UUID, cloneRoot: String) -> String? {
        guard let index = workspace.projects.firstIndex(where: { $0.id == cloneID }) else {
            return "the clone was already removed"
        }
        performRemoveProject(at: index)
        if let error = CloneRunner.deleteCloneDirectory(at: cloneRoot) {
            return "clone removed from zetty, but its directory couldn't be deleted: \(error)"
        }
        return nil
    }

    /// Closes the targeted pane (CLI `close`): the pane collapses into its
    /// split; a tab's last pane — or `wholeTab` — closes the tab. Selects the
    /// owning project/tab first so the standard close paths (and their zmx
    /// session cleanup) apply, then restores the user's prior selection —
    /// an agent closing a background pane must not yank the visible view to
    /// another project. Returns an error message, or nil on success.
    func closePane(target: PaneSelector, wholeTab: Bool) -> String? {
        do {
            let pane = try target.resolve(in: statusSnapshot().panes)
            guard let location = locate(shortID: pane.id) else { return "pane \(pane.id) not found" }
            // Identity, not index: closing never removes a project, but the
            // sidebar is sorted, so resolve back by id when restoring.
            let previousProjectID = workspace.activeProject.id
            let cameFromOtherProject = location.projectIndex != workspace.activeIndex
            defer {
                if cameFromOtherProject,
                   let back = workspace.projects.firstIndex(where: { $0.id == previousProjectID }),
                   back != workspace.activeIndex {
                    selectProject(at: back)
                }
            }
            if cameFromOtherProject {
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
                closeTab(atIndex: location.tabIndex, confirmIfBusy: false)
            } else {
                closePane(surfaceID: location.surfaceID, confirmIfBusy: false)
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

    /// Splits the targeted pane (CLI `split`) and returns the new pane's id.
    func splitPane(target: PaneSelector, vertical: Bool, focus: Bool = false) -> Result<String, ControlError> {
        do {
            let pane = try target.resolve(in: statusSnapshot().panes)
            guard let location = locate(shortID: pane.id) else {
                return .failure(.noSuchPane("pane \(pane.id) not found"))
            }
            let tabList = workspace.projects[location.projectIndex].tabList
            let workingDir = tabList.trees[location.tabIndex].layout.surfaces
                .first(where: { $0.id == location.surfaceID })?.workingDir ?? NSHomeDirectory()
            let newSurface = Surface(workingDir: workingDir)
            guard let newID = tabList.splitPane(
                inTreeAt: location.tabIndex, paneID: location.surfaceID,
                direction: vertical ? .vertical : .horizontal, newSurface: newSurface
            ) else {
                return .failure(.noSuchPane("split failed"))
            }

            if focus {
                focusPane(at: (location.projectIndex, location.tabIndex, newID))
            } else if location.projectIndex == workspace.activeIndex,
                      tabList.activeIndex == location.tabIndex {
                // Visible tree: show the new split, keep the caret on the user's
                // pane (splitPane restored focus to the original in-model).
                rebuildSurfaceNodeView()
                refreshSidebar()
                if let focused = focusedTerminalView() {
                    view.window?.makeFirstResponder(focused)
                }
            } else {
                refreshSidebar()
            }
            onWorkspaceDidChange?()
            return .success(SessionPersistence.shortID(for: newID))
        } catch {
            return .failure(.noSuchPane(error.localizedDescription))
        }
    }

    /// Break the targeted pane into a new adjacent tab (CLI `break`), returning
    /// the moved pane's short id. Fails when the pane's tab has a single pane.
    func breakPaneToTab(target: PaneSelector, focus: Bool = false) -> Result<String, ControlError> {
        do {
            let pane = try target.resolve(in: statusSnapshot().panes)
            guard let location = locate(shortID: pane.id) else {
                return .failure(.noSuchPane("pane \(pane.id) not found"))
            }
            let tabList = workspace.projects[location.projectIndex].tabList
            guard let movedID = tabList.breakPaneToNewTab(
                inTreeAt: location.tabIndex, paneID: location.surfaceID
            ) else {
                return .failure(.noSuchPane("pane \(pane.id) is the only pane in its tab"))
            }
            let newTabIndex = location.tabIndex + 1

            if focus {
                if location.projectIndex != workspace.activeIndex {
                    selectProject(at: location.projectIndex)
                }
                tabList.select(index: newTabIndex)
                refreshTabBar()
                rebuildSurfaceNodeView()
                refreshSidebar()
                if let focused = focusedTerminalView() {
                    view.window?.makeFirstResponder(focused)
                }
            } else {
                refreshTabBar()
                refreshSidebar()
                if location.projectIndex == workspace.activeIndex {
                    // The pane left the visible tab — re-render and keep focus on
                    // whatever pane the visible tab now focuses.
                    rebuildSurfaceNodeView()
                    if let focused = focusedTerminalView() {
                        view.window?.makeFirstResponder(focused)
                    }
                }
            }
            onWorkspaceDidChange?()
            return .success(SessionPersistence.shortID(for: movedID))
        } catch {
            return .failure(.noSuchPane(error.localizedDescription))
        }
    }

    /// Focuses the targeted pane (CLI `focus`), selecting its project and tab.
    /// Returns an error message, or nil on success.
    func focusPane(target: PaneSelector) -> String? {
        do {
            let pane = try target.resolve(in: statusSnapshot().panes)
            guard let location = locate(shortID: pane.id) else { return "pane \(pane.id) not found" }
            focusPane(at: location)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Everything the control socket's queue needs to run a blocking
    /// `zmx history` for CLI `capture` without touching main-thread state.
    struct CaptureSource {
        let session: String
        let zmxPath: String
        let paneID: String
    }

    /// Resolves the target pane to its preserved zmx session (CLI `capture`).
    /// Main-thread only (reads UI/workspace state); the caller runs the
    /// blocking `zmx history` subprocess OFF main with the returned source,
    /// so a slow/hung zmx can't freeze the UI.
    func captureSource(target: PaneSelector) -> Result<CaptureSource, ControlError> {
        do {
            let pane = try target.resolve(in: statusSnapshot().panes)
            guard let surface = surface(withShortID: pane.id) else {
                return .failure(.noSuchPane("pane \(pane.id) not found"))
            }
            guard let zmx = ZmxRunner.locate() else {
                return .failure(.noSuchPane("zmx is not installed"))
            }
            return .success(CaptureSource(
                session: SessionPersistence.sessionName(for: surface.id),
                zmxPath: zmx,
                paneID: pane.id
            ))
        } catch {
            return .failure(.noSuchPane(error.localizedDescription))
        }
    }

    /// Makes the pane at `location` the focused pane of the visible tab.
    private func focusPane(at location: (projectIndex: Int, tabIndex: Int, surfaceID: UUID)) {
        if location.projectIndex != workspace.activeIndex {
            selectProject(at: location.projectIndex)
        }
        let tabList = workspace.activeTabList
        if tabList.activeIndex != location.tabIndex {
            tabList.select(index: location.tabIndex)
        }
        paneTree.focus(location.surfaceID)
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        if let focusedView = focusedTerminalView() {
            view.window?.makeFirstResponder(focusedView)
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

    // MARK: - Open in editor (status bar)

    private func focusedDirectoryURL() -> URL {
        let focused = paneTree.focusedSurface
        let path = focused.flatMap { registry.workingDirectory(for: $0) }
            ?? focused?.workingDir
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The "Open" picker: installed editors + Reveal in Finder. Nothing
    /// happens until an item is selected.
    private func showEditorMenu(from anchor: NSView) {
        let menu = NSMenu()
        for app in EditorCatalog.installed() {
            let item = NSMenuItem(title: EditorCatalog.displayName(of: app),
                                  action: #selector(editorMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.image = EditorCatalog.icon(for: app, size: 16)
            item.representedObject = app
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let finder = NSMenuItem(title: "Finder",
                                action: #selector(revealFocusedInFinder(_:)), keyEquivalent: "")
        finder.target = self
        if let finderApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            finder.image = EditorCatalog.icon(for: finderApp, size: 16)
        }
        menu.addItem(finder)
        // Anchor above the pill (the status bar sits at the window bottom).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: anchor)
    }

    @objc private func editorMenuPicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open([focusedDirectoryURL()], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func revealFocusedInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([focusedDirectoryURL()])
    }

    /// Surfaces already given their post-reattach repaint nudge.
    private var nudgedSurfaces: Set<UUID> = []

    private var reattachNudgeScheduled = false

    /// Repaint nudge for preserved panes. A zmx reattach replays the screen,
    /// but a running TUI paints only deltas on top of what it believes is on
    /// screen — the pane stays half-drawn until a size change forces a full
    /// redraw (user-confirmed: resizing the WINDOW fixes it). Resizing the pane
    /// view directly doesn't work: it's Auto-Layout-pinned, so the constraint
    /// system reverts the frame before libghostty registers a real resize. So
    /// we nudge the window by 1pt and restore it, exactly like the manual fix —
    /// which repaints every reattached pane at once. Debounced so simultaneous
    /// reattaches trigger a single nudge.
    private func nudgeAfterReattach(_ surfaceID: UUID) {
        guard sessionCommandProvider != nil, !nudgedSurfaces.contains(surfaceID) else { return }
        nudgedSurfaces.insert(surfaceID)
        guard !reattachNudgeScheduled else { return }
        reattachNudgeScheduled = true
        // Fire after reattach/scrollback replay has settled, else the repaint
        // races the still-arriving output.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.reattachNudgeScheduled = false
            guard let window = self.view.window else { return }
            let frame = window.frame
            var shrunk = frame
            shrunk.size.height -= 1
            window.setFrame(shrunk, display: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                window.setFrame(frame, display: true)
            }
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

    /// Panes whose last emitted title outlived the tool that emitted it (the
    /// probe saw them go idle). Their titles are suppressed — the tab shows
    /// the directory instead — until the terminal emits a fresh title.
    private var staleTitleSurfaces: Set<UUID> = []

    private func markTitleStale(_ surfaceID: UUID) {
        staleTitleSurfaces.insert(surfaceID)
        // Clear the persisted copy too, or a relaunch would reseed the stale
        // name (the probe would re-mark it, but only after the first poll).
        for project in workspace.projects
        where project.tabList.updateSurface(surfaceID, { $0.lastTitle = nil }) {
            break
        }
    }

    /// The pane's display title: live terminal title, falling back to the
    /// persisted one — unless the title is known-stale (tool exited).
    private func displayTitle(for surface: Surface?) -> String? {
        guard let surface else { return nil }
        guard !staleTitleSurfaces.contains(surface.id) else {
            return registry.title(for: surface)   // only a FRESH live title counts
        }
        return registry.title(for: surface) ?? surface.lastTitle
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
            let surfaceTitle = displayTitle(for: focusedSurface)
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
        // Scratch terminals are disposable: every tab is closable (closing the
        // last one closes the scratch project), so always show the × there.
        tabBarView?.update(titles: titles, icons: icons, selectedIndex: tabList.activeIndex,
                           alwaysShowClose: workspace.activeProject.isScratch)
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
                    let surfaceTitle = displayTitle(for: focusedSurface)
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
            // Single-tab projects carry their pane's tool logo on the row
            // itself (there are no tab child rows to show it on).
            let projectIcon = trees.count == 1 ? agentIcon(for: trees[0].focusedSurface) : nil
            let identity = projectIdentity?(project)
            return SidebarProject(
                name: project.name,
                isPinned: project.isPinned,
                tabTitles: tabTitles,
                tabStatuses: tabStatuses,
                tabIcons: tabIcons,
                icon: projectIcon,
                status: rollup,
                projectColor: identity?.color,
                customGlyph: identity?.glyph,
                isHibernated: project.isHibernated,
                isScratch: project.isScratch,
                isHome: project.isHome,
                isClone: project.cloneSource != nil,
                cloneSourceIndex: project.cloneSource.flatMap { src in
                    workspace.projects.firstIndex { $0.rootPath == src && $0.cloneSource == nil }
                }
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

    private var addProjectGitCheckbox: NSButton?

    /// Presents a directory picker to choose — or, via macOS's built-in New
    /// Folder button, create — a folder, then adds it as a project. A single
    /// "Initialize git repository" checkbox git-inits the chosen folder. This is
    /// the one unified entry point (sidebar "+", ⌘O, ⇧⌘N, palette all land here).
    @objc func addProject(_ sender: Any?) {
        presentAddProjectPanel()
    }

    private func presentAddProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose or create a folder to add as a project"

        // Accessory: a single "Initialize git repository" checkbox.
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 32))
        let gitCheck = NSButton(checkboxWithTitle: "Initialize git repository", target: nil, action: nil)
        gitCheck.state = .off
        gitCheck.contentTintColor = ZTheme.current.fg2Color
        gitCheck.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(gitCheck)
        NSLayoutConstraint.activate([
            gitCheck.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 16),
            gitCheck.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
        ])
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        addProjectGitCheckbox = gitCheck

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            defer { self.addProjectGitCheckbox = nil }
            guard response == .OK, let url = panel.url else { return }
            if gitCheck.state == .on { self.gitInitIfNeeded(atPath: url.path) }
            self.addProjectFromURL(url)
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Adds the directory as a project and returns it. `activate` (default true)
    /// switches to the new project and focuses its pane; pass false to add it in
    /// the background without disturbing the current view (its pane spawns lazily
    /// when the project is later opened).
    @discardableResult
    private func addProjectFromURL(_ url: URL, name: String? = nil, activate: Bool = true) -> ProjectRuntime {
        let project = workspace.addProject(
            name: name ?? url.lastPathComponent, rootPath: url.path, makeActive: activate)
        // A resolved layout template replaces the default single-pane seed
        // (fresh project → nothing to confirm-discard).
        if let template = layoutTemplateProvider?(project),
           let built = template.tabList(rootPath: project.rootPath) {
            project.tabList.replaceTrees(from: built.tabList)
            pendingStartupCommands.merge(built.commands) { _, new in new }
        }
        refreshTabBar()
        refreshSidebar()
        if activate {
            onActiveProjectChanged?()
            rebuildSurfaceNodeView()   // spawns the pane + autosaves
            if let focused = focusedTerminalView() {
                view.window?.makeFirstResponder(focused)
            }
        } else {
            onWorkspaceDidChange?()     // persist the added project
        }
        return project
    }

    /// Interactive entry (⌃⌘N / palette / menu): always switches to the new
    /// scratch terminal. Scratch projects live only in the Scratch sidebar
    /// section and are never persisted.
    @objc func newScratchTerminal(_ sender: Any? = nil) {
        _ = newScratchTerminal(focus: true)
    }

    /// Creates a project-less, ephemeral scratch terminal rooted at home. When
    /// `focus` is true it becomes active and spawns immediately; when false it is
    /// added to the Scratch section without stealing the current view (its shell
    /// spawns when first viewed). Returns the new pane's short id.
    @discardableResult
    func newScratchTerminal(focus: Bool) -> String {
        let project = workspace.addScratchProject(makeActive: focus)
        refreshTabBar()
        refreshSidebar()
        if focus {
            onActiveProjectChanged?()
            rebuildSurfaceNodeView()   // spawns the pane
            if let focused = focusedTerminalView() {
                view.window?.makeFirstResponder(focused)
            }
        } else {
            onWorkspaceDidChange?()     // persist without switching
        }
        let surface = project.tabList.activeTree.focusedSurface
            ?? project.tabList.activeTree.layout.surfaces[0]
        return SessionPersistence.shortID(for: surface.id)
    }

    /// Closes and clears every scratch terminal at once (palette / CLI), killing
    /// their shells and returning focus to the first pinned project. No-op when
    /// there are no scratch terminals.
    @objc func closeAllScratchTerminals(_ sender: Any? = nil) {
        let surfaces = workspace.projects.filter(\.isScratch)
            .flatMap { $0.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) } }
        guard !surfaces.isEmpty else { return }
        guard confirmClosingBusyPanes(surfaces, what: "scratch terminals") else { return }
        workspace.removeScratchProjects()
        onActiveProjectChanged?()
        onSurfacesClosed?(surfaces)   // kill sessions + drop cwd files
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        onWorkspaceDidChange?()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    /// Runs `git init` on `path` unless it is already a git repository. A failed
    /// init is surfaced as a non-blocking warning — the project is still added.
    private func gitInitIfNeeded(atPath path: String) {
        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard !FileManager.default.fileExists(atPath: gitDir) else { return }
        if let message = runGitInit(atPath: path) {
            presentGitInitWarning("The project was added, but git init failed:\n\(message)")
        }
    }

    private func presentGitInitWarning(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Project added"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    // MARK: - Remove Project

    /// Removes the active project after confirmation.  Menu: Project → Remove Project…
    @objc func removeProject(_ sender: Any?) {
        confirmRemoveProject(at: workspace.activeIndex)
    }

    /// Asks for confirmation, then removes the project at `index`, closing all
    /// of its tabs/panes (which ends their zmx sessions).  The last remaining
    /// project can't be removed.
    private func confirmRemoveProject(at index: Int) {
        guard workspace.projects.count > 1,
              workspace.projects.indices.contains(index) else { return }
        if workspace.projects[index].cloneSource != nil {
            return confirmRemoveClone(at: index)
        }
        let project = workspace.projects[index]
        let tabCount = project.tabList.trees.count

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove project “\(project.name)”?"
        alert.informativeText = "This closes its \(tabCount) tab\(tabCount == 1 ? "" : "s")"
            + " and ends their sessions. The directory on disk is not affected."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        // Re-resolve by identity on confirm — indices can shift while the
        // sheet is up (e.g. a CLI-driven workspace change).
        let projectID = project.id
        let confirm: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let current = self.workspace.projects.firstIndex(where: { $0.id == projectID })
            else { return }
            self.performRemoveProject(at: current)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: confirm)
        } else {
            confirm(alert.runModal())
        }
    }

    private func performRemoveProject(at index: Int) {
        let wasScratch = workspace.projects[index].isScratch
        let closingSurfaces = workspace.projects[index].tabList.trees
            .flatMap { $0.layout.surfaces.map(\.id) }
        let countBefore = workspace.projects.count
        workspace.removeProject(at: index)
        guard workspace.projects.count != countBefore else { return }   // last project — no-op
        // Closing the last scratch terminal returns focus to the first pinned
        // project (or the first project if none are pinned), rather than
        // whichever neighbour `removeProject` happened to land on.
        if wasScratch, !workspace.projects.contains(where: \.isScratch) {
            workspace.select(index: workspace.projects.firstIndex(where: \.isPinned) ?? 0)
        }
        onActiveProjectChanged?()   // removal can shift which project is active
        // Same reasoning as closeTab: report the closed surfaces explicitly so
        // never-spawned panes' zmx sessions are killed too.
        onSurfacesClosed?(closingSurfaces)
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        onWorkspaceDidChange?()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    // MARK: - Remove Clone (fetch-back + guarded delete)

    /// Probes the clone's git state off-main, then offers: fetch the clone's
    /// branch back into the original repo and delete (default) · delete without
    /// fetching · cancel. Fetch failure ABORTS — nothing is deleted.
    private func confirmRemoveClone(at index: Int) {
        guard workspace.projects.indices.contains(index) else { return }
        let clone = workspace.projects[index]
        guard let sourcePath = clone.cloneSource else { return }
        let cloneID = clone.id
        let cloneRoot = clone.rootPath
        // The fetch target must still exist as a real directory (orphaned clones
        // degrade to delete-with-warning).
        var isDir: ObjCBool = false
        let sourceExists = FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDir)
            && isDir.boolValue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = CloneRunner.probeWorkState(cloneRoot: cloneRoot, sourceRoot: sourcePath)
            DispatchQueue.main.async {
                self?.presentRemoveCloneDialog(cloneID: cloneID, state: state,
                                               sourceExists: sourceExists)
            }
        }
    }

    private func presentRemoveCloneDialog(cloneID: UUID, state: CloneWorkState, sourceExists: Bool) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == cloneID }) else { return }
        let clone = workspace.projects[index]
        let offerFetch: Bool
        switch state {
        case .clean:                 offerFetch = false
        case .unfetched:             offerFetch = sourceExists
        case .dirty(let unfetched):  offerFetch = sourceExists && unfetched
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove clone “\(clone.name)”?"
        var lines = ["This closes its tabs, ends their sessions, and deletes \(clone.rootPath)."]
        if case .dirty = state {
            lines.append("⚠ The clone has UNCOMMITTED changes that will be lost.")
        }
        if offerFetch {
            lines.append("“Fetch & Delete” first lands its branch in the original repo"
                + " so its commits survive; merge with your normal tools.")
        } else if case .unfetched = state {
            lines.append("⚠ The clone has commits the original never fetched, and the"
                + " original directory is gone — deleting loses them.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        if offerFetch {
            alert.addButton(withTitle: "Fetch & Delete")
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
        }

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self,
                  let current = self.workspace.projects.firstIndex(where: { $0.id == cloneID })
            else { return }
            let cloneRoot = self.workspace.projects[current].rootPath
            let sourceRoot = self.workspace.projects[current].cloneSource
            let fetchChosen = offerFetch && response == .alertFirstButtonReturn
            let deleteChosen = fetchChosen
                || (offerFetch && response == .alertSecondButtonReturn)
                || (!offerFetch && response == .alertFirstButtonReturn)
            guard deleteChosen else { return }
            if fetchChosen, let sourceRoot {
                // The clone repo's CURRENT branch carries the work — robust
                // against project renames (never derived from the display name).
                guard let branch = CloneRunner.currentBranch(in: cloneRoot) else {
                    self.presentCloneError("Fetch-back failed — the clone has no current"
                        + " branch (detached HEAD?). Nothing was deleted.",
                        title: "Remove clone failed")
                    return
                }
                if let error = CloneRunner.fetchBack(sourceRoot: sourceRoot,
                                                     clonePath: cloneRoot, branch: branch) {
                    self.presentCloneError("Fetch-back failed — nothing was deleted:\n\(error)",
                        title: "Remove clone failed")
                    return
                }
            }
            self.performRemoveProject(at: current)
            if let error = CloneRunner.deleteCloneDirectory(at: cloneRoot) {
                self.presentCloneError("The clone was removed from zetty, but its directory"
                    + " couldn't be deleted:\n\(error)", title: "Remove clone failed")
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(alert.runModal())
        }
    }

    // MARK: - Tab actions (responder-chain targets)

    /// Open a new tab and focus its single fresh pane.  Key equivalent: ⌘T.
    @objc func newTab(_ sender: Any?) {
        chooseAgentThenSpawn { [weak self] command in
            self?.performNewTab(startupCommand: command)
        }
    }

    /// Close the active tab.  No-op if it is the only tab.  Key equivalent: ⇧⌘W.
    @objc func closeTab(_ sender: Any?) {
        closeTab(atIndex: workspace.activeTabList.activeIndex)
    }

    /// Asks before closing panes that are still running something. The
    /// zmx/ps foreground probe is the source of truth ("" or no entry =
    /// idle shell → no prompt). Returns true when it's OK to close.
    func confirmClosingBusyPanes(_ surfaceIDs: [UUID], what: String) -> Bool {
        let running = surfaceIDs.compactMap { id -> String? in
            guard let command = foregroundBySurface[id], !command.isEmpty else { return nil }
            return command
        }
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Close \(what)?"
        alert.informativeText = "Still running: \(Set(running).sorted().joined(separator: ", ")). "
            + "Closing kills the session\(running.count > 1 ? "s" : "")."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Close the tab at an explicit index (called by the tab bar × button).
    /// No-op if it is the only tab. `confirmIfBusy: false` (the CLI path)
    /// skips the busy-pane prompt — `zetty close` is documented as
    /// no-confirmation, and a modal would block the control socket.
    func closeTab(atIndex index: Int, confirmIfBusy: Bool = true) {
        let tabList = workspace.activeTabList
        guard tabList.trees.indices.contains(index) else { return }

        // A scratch terminal's last tab closes the whole (ephemeral) scratch
        // project; a normal project keeps its last tab (no-op).
        if tabList.trees.count == 1 {
            guard workspace.activeProject.isScratch else { return }
            let closing = tabList.trees[index].layout.surfaces.map(\.id)
            if confirmIfBusy {
                guard confirmClosingBusyPanes(closing, what: "Terminal") else { return }
            }
            performRemoveProject(at: workspace.activeIndex)
            return
        }

        let closingSurfaces = tabList.trees[index].layout.surfaces.map(\.id)
        if confirmIfBusy {
            guard confirmClosingBusyPanes(closingSurfaces, what: "Tab") else { return }
        }
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

    /// ⌘1…⌘9 — jump to tab N in the active project. The menu item's tag
    /// carries the zero-based tab index; out-of-range numbers are no-ops.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.tag,
              workspace.activeTabList.trees.indices.contains(index) else { return }
        selectTab(at: index)
    }

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
        onActiveProjectChanged?()
        refreshTabBar()
        rebuildSurfaceNodeView()
        refreshSidebar()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    // MARK: - Hibernation

    /// Global timeout (seconds, 0 = off) + per-project opt-out, wired from AppDelegate.
    var autoHibernateAfter: (() -> TimeInterval)?
    var autoHibernateDisabled: ((ProjectRuntime) -> Bool)?

    private var lastActiveAt: [UUID: Date] = [:]
    private var hibernationTimer: Timer?

    /// Frees a project's sessions, processes, and panes; keeps its layout.
    /// Never hibernates the active project (switches away first).
    func hibernateProject(_ project: ProjectRuntime, confirmIfBusy: Bool = true) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == project.id }),
              !project.isHibernated else { return }
        let surfaceIDs = project.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }
        if confirmIfBusy, !confirmClosingBusyPanes(surfaceIDs, what: "project “\(project.name)”") { return }

        if index == workspace.activeIndex {
            // Switch to another awake project if one exists; otherwise stay put
            // and let the dormant placeholder render (full dormancy is allowed —
            // Home guarantees the workspace is never gone, only dormant).
            if let target = workspace.projects.indices.first(where: {
                $0 != index && !workspace.projects[$0].isHibernated
            }) {
                workspace.select(index: target)
            }
        }
        project.isHibernated = true
        onSurfacesClosed?(surfaceIDs)          // kill zmx sessions
        onActiveProjectChanged?()
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()               // prune tears down its surfaces
        onWorkspaceDidChange?()
        if let focused = focusedTerminalView() { view.window?.makeFirstResponder(focused) }
    }

    /// Wakes a hibernated project: fresh shells at each pane's cwd, layout intact.
    func wakeProject(_ project: ProjectRuntime) {
        guard project.isHibernated,
              let index = workspace.projects.firstIndex(where: { $0.id == project.id }) else { return }
        project.isHibernated = false
        lastActiveAt[project.id] = Date()
        workspace.select(index: index)
        onActiveProjectChanged?()
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()               // re-creates surfaces → fresh shells
        onWorkspaceDidChange?()
        if let focused = focusedTerminalView() { view.window?.makeFirstResponder(focused) }
    }

    /// Hibernate the named project (CLI, case-insensitive). No confirmation —
    /// the CLI call IS the confirmation. Returns an error message or nil.
    func hibernateProjectNamed(_ name: String) -> String? {
        let matches = workspace.projects.filter { $0.name.lowercased() == name.lowercased() }
        guard let project = matches.first else { return "no project named \"\(name)\"" }
        guard matches.count == 1 else { return "\(matches.count) projects named \"\(name)\" — use the sidebar" }
        guard workspace.projects.count > 1 else { return "cannot hibernate the only project" }
        guard !project.isHibernated else { return "project \"\(project.name)\" is already hibernated" }
        hibernateProject(project, confirmIfBusy: false)
        return nil
    }

    /// Wake the named project (CLI, case-insensitive). Returns an error or nil.
    func wakeProjectNamed(_ name: String) -> String? {
        let matches = workspace.projects.filter { $0.name.lowercased() == name.lowercased() }
        guard let project = matches.first else { return "no project named \"\(name)\"" }
        guard matches.count == 1 else { return "\(matches.count) projects named \"\(name)\" — use the sidebar" }
        guard project.isHibernated else { return "project \"\(project.name)\" is not hibernated" }
        wakeProject(project)
        return nil
    }

    /// Toggles hibernate/wake for the project at `index` (sidebar menu).
    func toggleHibernation(at index: Int) {
        guard workspace.projects.indices.contains(index) else { return }
        let project = workspace.projects[index]
        if project.isHibernated { wakeProject(project) } else { hibernateProject(project) }
    }

    /// A project is busy if any pane runs a foreground command or a live agent —
    /// such projects are never auto-hibernated.
    private func projectIsBusy(_ project: ProjectRuntime) -> Bool {
        for tree in project.tabList.trees {
            for surface in tree.layout.surfaces {
                if !(foregroundBySurface[surface.id] ?? "").isEmpty { return true }
                let status = agentDetector.state(for: surface.id).status
                if status == .running || status == .needsAttention { return true }
            }
        }
        return false
    }

    /// Starts the auto-hibernation timer (safe to call repeatedly, e.g. on reload).
    func startHibernationTimer() {
        hibernationTimer?.invalidate()
        hibernationTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evaluateAutoHibernation()
        }
    }

    private func evaluateAutoHibernation() {
        let after = autoHibernateAfter?() ?? 0
        guard after > 0, workspace.projects.count > 1 else { return }
        let now = Date()
        let activeID = workspace.activeProject.id
        lastActiveAt[activeID] = now   // the active project is continuously "seen"
        for project in workspace.projects where project.id != activeID {
            let seen = lastActiveAt[project.id] ?? now   // first sight: full window before eligible
            lastActiveAt[project.id] = seen
            if HibernationPolicy.shouldHibernate(
                idleFor: now.timeIntervalSince(seen),
                hibernateAfter: after,
                isBusy: projectIsBusy(project),
                isActive: false,
                isHibernated: project.isHibernated,
                autoDisabled: autoHibernateDisabled?(project) ?? false) {
                hibernateProject(project, confirmIfBusy: false)
            }
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

        // Any layout/tab change invalidates an active copy-mode session (its
        // selection and viewport-relative cursor no longer mean anything).
        exitCopyModeIfActive()

        rootContentView?.removeFromSuperview()
        rootContentView = nil
        placeholderView?.removeFromSuperview()
        placeholderView = nil

        // Pin below the tab bar (28 pt), or to the top if there is no tab bar yet;
        // and above the status bar (if present), else to the container bottom.
        let topGuide: NSLayoutYAxisAnchor = tabBarView?.bottomAnchor ?? container.topAnchor
        let bottomGuide = statusBarView?.topAnchor ?? container.bottomAnchor

        // Active project hibernated → render a dormant placeholder (status +
        // Wake button) instead of terminal panes. Viewing never wakes it; the
        // button (or context menu / palette / CLI) is the intentional wake.
        if workspace.activeProject.isHibernated {
            let project = workspace.activeProject
            let placeholder = HibernationPlaceholderView(
                projectName: project.name,
                tabCount: project.tabList.trees.count
            ) { [weak self] in self?.wakeProject(project) }
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.topAnchor.constraint(equalTo: topGuide),
                placeholder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                placeholder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                placeholder.bottomAnchor.constraint(equalTo: bottomGuide),
            ])
            placeholderView = placeholder
            registry.prune(keeping: Set(allSurfaceIDs))   // free the frozen surfaces
            onWorkspaceDidChange?()
            return
        }

        // A zoomed pane renders alone (tmux prefix+z). Background panes stay
        // alive — pruning uses the union of ALL surfaces, not the rendered node.
        let renderedNode: SurfaceNode
        if let zoomedID = paneTree.zoomedSurfaceID,
           let zoomed = paneTree.layout.surfaces.first(where: { $0.id == zoomedID }) {
            renderedNode = .leaf(zoomed)
        } else {
            renderedNode = paneTree.layout.root
        }

        let showsClose = paneTree.layout.surfaces.count > 1
        let newRoot = SurfaceNodeView(
            node: renderedNode,
            registry: registry,
            focusedSurfaceID: paneTree.focusedSurfaceID,
            showsClose: showsClose,
            onClose: { [weak self] id in self?.closePane(surfaceID: id) },
            onBreak: { [weak self] id in self?.breakPane(surfaceID: id) },
            onRatioChange: { [weak self] path, ratio in
                // Write the dragged divider position back to the model (no
                // rebuild — the view already shows it) and autosave.
                guard let self else { return }
                if self.paneTree.layout.setRatio(at: path, to: ratio) {
                    self.onWorkspaceDidChange?()
                }
            }
        )
        newRoot.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(newRoot)

        NSLayoutConstraint.activate([
            newRoot.topAnchor.constraint(equalTo: topGuide),
            newRoot.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            newRoot.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            newRoot.bottomAnchor.constraint(equalTo: bottomGuide),
        ])
        rootContentView = newRoot

        // Prune to the union of ALL awake projects' surfaces so background
        // sessions survive project/tab switches — but hibernated projects'
        // surfaces are freed (allSurfaceIDs excludes them).
        registry.prune(keeping: Set(allSurfaceIDs))

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
        // Visiting a needs-attention pane marks it read — even when the pane
        // was already this tab's focused surface (early return below).
        acknowledgeAttention(for: surfaceID)
        guard paneTree.focusedSurfaceID != surfaceID else { return }
        // Focus moving to a different pane abandons an active copy-mode session.
        if copyMode.activeSurfaceID != nil, copyMode.activeSurfaceID != surfaceID {
            exitCopyModeIfActive()
        }
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

// MARK: - NSMenuItemValidation

extension TerminalViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(removeProject(_:)) {
            return workspace.projects.count > 1
        }
        if menuItem.action == #selector(breakPaneIntoTab(_:)) {
            return workspace.activeTabList.activeTree.layout.surfaces.count > 1
        }
        return true
    }
}
