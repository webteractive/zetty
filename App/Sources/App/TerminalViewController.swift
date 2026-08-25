import AppKit
import ZettyGhostty

struct MenuBarTabSnapshot {
    let index: Int
    let title: String
    let status: AgentStatus?
    let isActive: Bool
}

struct MenuBarProjectSnapshot {
    let id: UUID
    let title: String
    let tabs: [MenuBarTabSnapshot]
    let status: AgentStatus?
    let isActive: Bool
}

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
    /// The caution strip shown below the tab bar when the active project is a
    /// clone (copy-on-write fork). Nil for ordinary projects.
    private var cloneWarningBanner: CloneWarningBanner?

    /// The tab bar strip shown above the pane area.
    private var tabBarView: TabBarView?

    /// The project sidebar shown on the left.
    private var sidebarView: SidebarView?

    /// The bottom status strip (cwd · scheme · shell · libghostty version).
    private var statusBarView: StatusBarView?

    /// The command palette overlay, when open.
    private var commandPaletteView: CommandPaletteView?
    /// The read-only file viewer overlay, when open.
    private var fileViewerOverlay: FileViewerOverlay?
    /// Supplies the viewer's config. A provider (like `agentsProvider`) so the
    /// controller never re-reads the config file itself.
    var viewerSettingsProvider: (() -> (highlightCommand: String, maxBytes: Int))?

    /// The `editor` config value (app name or bundle id), or nil when unset.
    /// Supplied by `AppDelegate`, never read from disk here.
    var editorProvider: (() -> String?)?
    /// ⌘-hover/⌘-click path detection over the terminal surfaces.
    private let pathHover = PathHoverTracker()
    /// Bumped per peek request so a slow load (a big file, a slow highlighter)
    /// can't land after a newer click and show the wrong file.
    private var fileViewerRequest = 0

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

    /// Slow re-probe of the focused pane's git state. The per-refresh probe is
    /// gated on the directory changing, so this is what still notices a commit,
    /// a branch switch, or a file edit made inside the pane.
    private var gitRefreshTimer: Timer?

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

    /// The directory the status bar's git pill currently reflects, so a status-bar
    /// refresh that didn't change directory doesn't spawn another `git` process.
    /// `refreshStatusBar` runs on every title tick; probing per call meant one
    /// subprocess per tick for a branch name that almost never changes.
    private var lastGitProbeDirectory: String?

    // MARK: - Coalesced chrome refresh

    /// Which parts of the chrome a coalesced refresh still owes.
    private struct ChromeRefreshNeeds {
        var tabBar = false
        var sidebar = false
        var isEmpty: Bool { !tabBar && !sidebar }
    }

    private var chromeNeeds = ChromeRefreshNeeds()
    private var chromeRefreshScheduled = false

    /// How long a title-driven refresh waits for more of its kind. Agent CLIs
    /// animate a spinner glyph in their terminal title, so a busy workspace
    /// emits title changes many times a second per pane; each one used to
    /// rebuild the tab bar and reload the whole sidebar synchronously.
    private static let chromeRefreshInterval: TimeInterval = 0.1

    /// Marks the chrome dirty and refreshes ONCE on the next tick.
    ///
    /// High-frequency, machine-driven refreshes (terminal titles, the
    /// foreground-process probe, agent hook events) must come through here.
    /// User-driven changes still call `refreshTabBar()`/`refreshSidebar()`
    /// directly so the UI reacts to input in the same run-loop turn.
    func setNeedsChromeRefresh(tabBar: Bool = false, sidebar: Bool = false) {
        if tabBar { chromeNeeds.tabBar = true }
        if sidebar { chromeNeeds.sidebar = true }
        guard !chromeNeeds.isEmpty, !chromeRefreshScheduled else { return }
        chromeRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chromeRefreshInterval) { [weak self] in
            guard let self else { return }
            self.chromeRefreshScheduled = false
            let needs = self.chromeNeeds
            self.chromeNeeds = ChromeRefreshNeeds()
            // refreshTabBar refreshes the status bar too, so don't double up.
            if needs.tabBar { self.refreshTabBar() }
            if needs.sidebar { self.refreshSidebar() }
        }
    }

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
    ///
    /// This is the FAST path — it ends a session the moment the user closes
    /// something. It is deliberately not the only path: see
    /// `reconcileSessions()`, which is the actual guarantee.
    var onSurfacesClosed: (([UUID]) -> Void)?

    // NOTE: `registry.onSurfacesRemoved` is deliberately left unset. Surfaces
    // leaving the registry means their GPU resources are freed — it does NOT
    // mean their sessions should die. Those were once the same event, which was
    // wrong in both directions: a pane closed before it was ever viewed had no
    // pair to prune, so its session leaked forever (a rogue shell), and freeing
    // a background project's surfaces to reclaim memory was impossible without
    // killing them. Session lifetime now follows *model ownership* only.

    // MARK: - Session reconciliation (the no-rogue-process guarantee)

    /// Kills every `zetty-*` zmx session that no surface in the workspace owns.
    ///
    /// Ownership is `WorkspaceModel.sessionOwnerSurfaceIDs` — ALL projects,
    /// hibernated included — so this can never kill a session that some pane
    /// still refers to, however dormant that pane is. It is idempotent and
    /// cheap (one `zmx list`), which is what lets it run as a sweep rather than
    /// relying on every close path remembering to clean up.
    ///
    /// Deliberately structural: the previous design needed an explicit
    /// `onSurfacesClosed` call at each of six close sites, and the two GUI ones
    /// (⌘W and the per-pane ×) simply didn't have it.
    func reconcileSessions() {
        let owned = sessionOwnerSurfaceIDs        // read on main; workspace is main-only
        let zmx = ZmxRunner.locate()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listed = zmx.map { ZmxRunner.listZettySessions(zmxPath: $0) } ?? []
            let candidates = SessionPersistence.orphans(existing: listed, liveSurfaceIDs: owned)
            let names = (try? FileManager.default
                .contentsOfDirectory(atPath: PaneCwdStore.directory.path)) ?? []
            let staleFiles = SessionPersistence.orphanCwdFiles(existing: names, liveSurfaceIDs: owned)
            guard !candidates.isEmpty || !staleFiles.isEmpty else { return }

            // Re-check ownership on main before destroying anything. `owned` was
            // sampled before the `zmx list` above, so a pane created in between
            // would own a session that this pass sees as an orphan — and killing
            // it would take out a brand-new shell, the exact failure this whole
            // mechanism exists to prevent. The model can't change under us here.
            DispatchQueue.main.async {
                guard let self else { return }
                let confirmed = Set(self.sessionOwnerSurfaceIDs.map(SessionPersistence.sessionName(for:)))
                let ownedNow = self.sessionOwnerSurfaceIDs.map { $0.uuidString.lowercased() }
                let killable = candidates.filter { !confirmed.contains($0) }
                let deletable = staleFiles.filter { name in
                    let stem = String(name.dropLast(SessionPersistence.cwdFileSuffix.count)).lowercased()
                    return !ownedNow.contains(stem)
                }
                guard !killable.isEmpty || !deletable.isEmpty else { return }
                DispatchQueue.global(qos: .utility).async {
                    if let zmx, !killable.isEmpty { ZmxRunner.kill(sessions: killable, zmxPath: zmx) }
                    // The cwd files are the same ownership question, so they are
                    // cleared in the same pass — a closed pane used to leave its
                    // `<uuid>.cwd` behind until the next launch wiped the directory.
                    let dir = PaneCwdStore.directory
                    for name in deletable {
                        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                    }
                }
            }
        }
    }

    /// Coalesces reconciliation so a burst of structural changes (closing a tab
    /// of five panes) costs one `zmx list`, and so it lands *after* the model
    /// has settled rather than mid-mutation.
    func setNeedsSessionReconcile() {
        guard !sessionReconcileScheduled else { return }
        sessionReconcileScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.sessionReconcileScheduled = false
            self.reconcileSessions()
        }
    }

    private var sessionReconcileScheduled = false

    /// Periodic backstop, so a session orphaned by a path nobody anticipated
    /// lives minutes rather than until the next launch.
    private func startSessionReconcileTimer() {
        sessionReconcileTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.reconcileSessions()
        }
    }

    private var sessionReconcileTimer: Timer?

    /// Every surface ID that should be *attached* right now. Hibernated projects
    /// are excluded so their surfaces are pruned (torn down) and never spawn
    /// until woken.
    ///
    /// NOT the set that owns preserved zmx sessions — a hibernated project's
    /// session must keep running. Use `sessionOwnerSurfaceIDs` for orphan
    /// diffing.
    var allSurfaceIDs: [UUID] {
        workspace.projects.filter { !$0.isHibernated }.flatMap { project in
            project.tabList.trees.flatMap { tree in
                tree.layout.surfaces.map(\.id)
            }
        }
    }

    /// Called when libghostty rejected a pane's merged configuration, so the
    /// pane fell back to Zetty's own directives (see
    /// `SurfaceRegistry.onConfigurationRejected`). The argument is ghostty's own
    /// diagnostic, when it reported one.
    var onGhosttyConfigurationRejected: ((String?) -> Void)? {
        didSet {
            let handler = onGhosttyConfigurationRejected
            registry.onConfigurationRejected = { issue in handler?(issue) }
        }
    }

    /// Every surface ID across ALL projects, hibernated included — the panes
    /// whose preserved zmx sessions this workspace owns (for orphan diffing).
    var sessionOwnerSurfaceIDs: [UUID] { workspace.sessionOwnerSurfaceIDs }

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
            // Coalesced: an animating agent title fires this many times a second.
            self.setNeedsChromeRefresh(tabBar: true, sidebar: true)
            // The subscription fires once when the pane's surface pair is
            // created, which makes this a reliable per-pane one-shot hook.
            self.nudgeAfterReattach(id)
            self.injectStartupCommandIfPending(id)
        }

        startAgentEventWatcher()
        startForegroundPolling()
        startGitRefreshPolling()
        startSessionReconcileTimer()
    }

    /// Re-probes the focused pane's git state on a slow cadence. Skipped while
    /// Zetty is in the background — the pill isn't visible and the next tick
    /// after reactivation catches up.
    private func startGitRefreshPolling() {
        gitRefreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive, let statusBar = self.statusBarView, !statusBar.isHidden
            else { return }
            guard let directory = self.lastGitProbeDirectory else { return }
            self.scheduleGitProbe(for: directory,
                                  surfaceID: self.paneTree.focusedSurfaceID,
                                  force: true)
        }
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
                self.setNeedsChromeRefresh(tabBar: true, sidebar: true)
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
        fileViewerOverlay?.applyTheme()
        registry.reapplyTerminalTheme(ZTheme.current.terminalTheme())
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        // An open overlay keeps focus — taking it back would break its Esc.
        if fileViewerOverlay == nil, let focused = focusedTerminalView() {
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
            self?.selectProject(at: projectIndex, tabIndex: tabIndex)
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

        sidebar.onAssignProjectToSpace = { [weak self] index, spaceID in
            self?.assignProject(at: index, to: spaceID)
        }
        sidebar.onMoveSpace = { [weak self] from, to in
            self?.moveSpace(from: from, to: to)
        }
        sidebar.onNewSpace = { [weak self] projectIndex in
            guard let self else { return }
            // Resolve the index to the actual project AT CLICK TIME, same
            // idiom as onRenameProject/onOpenProjectSettings below — the sheet
            // is async and the workspace can be restructured while it's open
            // (a background clone landing, a CLI remove-project, a re-pin),
            // so an index re-read inside the completion handler could name a
            // different project by then.
            let project = projectIndex.flatMap { self.workspace.projects.indices.contains($0) ? self.workspace.projects[$0] : nil }
            self.promptNewSpace(assigning: project)
        }
        sidebar.onEditSpace = { [weak self] id in self?.promptEditSpace(id) }
        sidebar.onDeleteSpace = { [weak self] id in self?.confirmDeleteSpace(id) }
        sidebar.onHibernateSpace = { [weak self] id, hibernate in
            guard let self, let space = self.workspace.spaces.first(where: { $0.id == id }) else { return }
            _ = hibernate ? self.hibernateSpaceNamed(space.name) : self.wakeSpaceNamed(space.name)
        }

        sidebar.onTogglePin = { [weak self] index in
            guard let self else { return }
            self.workspace.togglePin(at: index)
            self.refreshSidebar()
            self.onWorkspaceDidChange?()
        }

        sidebar.onToggleSpaceCollapsed = { [weak self] id in
            guard let self, let space = self.workspace.spaces.first(where: { $0.id == id }) else { return }
            self.setSpaceCollapsed(id, !space.isCollapsed)
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

        sidebar.onMergeToSource = { [weak self] index in
            self?.confirmMergeToSource(at: index)
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
        // This runs on the same cadence that notices a cwd change, so it is the
        // natural place to re-root any visible file tree. Debounced inside —
        // agents `cd` several times a second.
        setNeedsFileTreeRootRefresh()
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

        pathHover.gridMetrics = { [weak self] id in self?.registry.viewState(for: id)?.surfaceSize }
        // Reuse copy mode's capture so there's exactly one implementation.
        pathHover.captureLines = copyMode.captureLines
        pathHover.paneCwd = { PaneCwdStore.read($0) }
        pathHover.projectRoot = { [weak self] id in
            self?.workspace.project(containing: id)?.rootPath
        }
        // Hit-test the real hierarchy rather than checking each surface's
        // bounds: `allSurfaceIDs` spans every non-hibernated project and tab,
        // and those views aren't in the window (so a bounds check can match a
        // hidden pane). It also means chrome — and an open file-viewer overlay —
        // correctly blocks detection instead of being peeked through.
        pathHover.terminalViewAndSurface = { [weak self] windowPoint in
            guard let self,
                  let hit = self.view.window?.contentView?.hitTest(windowPoint)
            else { return nil }
            var candidate: NSView? = hit
            while let current = candidate {
                if let terminal = current as? AppTerminalView {
                    guard let id = self.allSurfaceIDs.first(where: {
                        self.registry.appTerminalView(for: $0) === terminal
                    }) else { return nil }
                    return (terminal, id)
                }
                candidate = current.superview
            }
            return nil
        }
        pathHover.onOpen = { [weak self] path, line, column in
            self?.presentFileViewer(path: path, line: line, column: column)
        }
        pathHover.install()
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
    private func scheduleGitProbe(for directory: String, surfaceID: UUID?, force: Bool = false) {
        // `refreshStatusBar` runs on every chrome refresh, but the focused
        // pane's directory almost never changes — probing per call spawned a
        // `git` process per tick. Re-probe on a directory change, or when a
        // caller explicitly wants fresh state (branch/dirtiness may have moved
        // under us without the cwd changing).
        if !force, directory == lastGitProbeDirectory { return }
        lastGitProbeDirectory = directory
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
        rotateAgentEventLog(at: url)
        let watcher = AgentEventWatcher(url: url) { [weak self] events in
            self?.handleAgentEvents(events)
        }
        watcher.start()
        agentEventWatcher = watcher
        replayAgentEvents(from: url)
    }

    /// Trims the hook-event log to a bounded tail, synchronously and BEFORE the
    /// watcher seeds its read offset — rotating under a live tail would leave
    /// that offset past the new end of file.
    ///
    /// Harness hooks append concurrently, so this is deliberately a startup-only,
    /// best-effort operation: the worst case is losing a status ping that raced
    /// the rewrite, and the next hook event restores the dot. Written atomically
    /// so a crash mid-rotation can't leave a truncated log behind.
    private func rotateAgentEventLog(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              let trimmed = AgentEventLogRotation.trimmed(data) else { return }
        try? trimmed.write(to: url, options: .atomic)
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

    /// Clones whose copy is in flight — rendered as transient "Cloning…"
    /// spinner rows spliced under their source (never persisted). Keyed by a
    /// token returned to the copy site so it can clear its own row on finish.
    private var pendingClones: [(id: UUID, sourceRootPath: String, displayName: String)] = []

    /// Registers a "Cloning…" placeholder row under the source and returns a
    /// token; call `endPendingClone` when the copy finishes (success or fail).
    func beginPendingClone(plan: ClonePlan) -> UUID {
        let id = UUID()
        pendingClones.append((id: id, sourceRootPath: plan.sourceRootPath,
                              displayName: plan.projectName))
        refreshSidebar()
        return id
    }

    /// Clears a "Cloning…" placeholder row (the real clone row, if the copy
    /// succeeded, comes in via `registerClone`'s own refresh).
    func endPendingClone(_ id: UUID) {
        pendingClones.removeAll { $0.id == id }
        refreshSidebar()
    }

    /// How long a freshly spawned pane needs before it reads its pty — the shell,
    /// or the scrollback-restore wrapper's `zmx attach`, has to start first or the
    /// text is written into nothing. Shared by template startup commands and by
    /// CLI `send` when it had to spawn the pane itself.
    private static let spawnGracePeriod: TimeInterval = 0.8

    /// Writes `payload` verbatim into a just-spawned pane once it can read.
    /// Re-resolves the surface at delivery time so a pane closed inside the grace
    /// period is simply skipped.
    private func deliverAfterSpawn(_ payload: String, to surfaceID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spawnGracePeriod) { [weak self] in
            guard let self, let surface = self.surface(with: surfaceID) else { return }
            _ = self.registry.sendText(payload, to: surface)
        }
    }

    /// Injects a template pane's startup command shortly after its view spawns.
    private func injectStartupCommandIfPending(_ surfaceID: UUID) {
        guard let command = pendingStartupCommands.removeValue(forKey: surfaceID) else { return }
        deliverAfterSpawn(command + "\r", to: surfaceID)
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
            setNeedsChromeRefresh(tabBar: true, sidebar: true)
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

    // MARK: - File viewer

    /// Peeks a file in the read-only overlay, scrolled to `line`. Returns nil
    /// on success or a message describing why it couldn't be shown. The single
    /// entry point for ⌘-click and `zetty view` alike.
    @discardableResult
    func presentFileViewer(path: String, line: Int?, column: Int?) -> String? {
        var isDirectory: ObjCBool = false
        // Both early returns log: the CLI shows its message to the caller, but
        // ⌘-click and the file tree discard it, so without this a peek that
        // never opened would leave no trace at all.
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            ZettyLog.viewer.error("peek: no such file \(path)")
            return "no such file: \(path)"
        }
        guard !isDirectory.boolValue else {
            ZettyLog.viewer.error("peek: not a file \(path)")
            return "not a file: \(path)"
        }

        let settings = viewerSettingsProvider?()
        let root = workspace.activeProject.rootPath
        fileViewerRequest += 1
        let request = fileViewerRequest
        // A blank peek is only ever reported as a screenshot of an empty panel,
        // so every step from here to the rendered glyphs narrates itself.
        ZettyLog.viewer.log("""
            peek #\(request) path=\(path) \
            line=\(line ?? -1) \
            scheme=\(ZTheme.scheme.rawValue) \
            isDark=\(ZTheme.current.isDark) \
            bg1=#\(ZTheme.current.bg1) fg=#\(ZTheme.current.fg) \
            highlight='\(settings?.highlightCommand ?? "")' \
            os=\(ProcessInfo.processInfo.operatingSystemVersionString)
            """)
        // The overlay is created only once the file is known to be text, so a
        // PDF or an image never flashes an empty panel on its way to Preview.
        FileViewerLoader.load(path: path, line: line,
                              highlightCommand: settings?.highlightCommand ?? "",
                              maxBytes: settings?.maxBytes ?? AppConfig.defaultViewerMaxBytes,
                              isDarkScheme: ZTheme.current.isDark) { [weak self] loaded in
            guard let self else { return }
            guard request == self.fileViewerRequest else {
                ZettyLog.viewer.log("""
                    peek #\(request) superseded by \
                    #\(self.fileViewerRequest) — dropped
                    """)
                return
            }
            if let action = loaded.externalAction {
                // Not text: hand it off. Any existing peek is left alone — this
                // was a different file.
                let url = URL(fileURLWithPath: loaded.path)
                switch action {
                case .openWithDefaultApp:
                    // Nothing claims this type → reveal rather than fail silently.
                    if !NSWorkspace.shared.open(url) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                case .revealInFinder:
                    // Launching would install or execute something, and the path
                    // came from untrusted terminal output. Show it instead.
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                return
            }
            self.showFileViewer(loaded, projectRoot: root)
        }
        return nil
    }

    /// Presents (or reuses) the overlay for a loaded text file. At most one peek
    /// exists per window, so a second click replaces the content rather than
    /// stacking panels.
    private func showFileViewer(_ loaded: FileViewerLoader.Loaded, projectRoot: String) {
        let overlay: FileViewerOverlay
        let reused = fileViewerOverlay != nil
        if let existing = fileViewerOverlay {
            overlay = existing
        } else {
            overlay = FileViewerOverlay(onClose: { [weak self] in self?.dismissFileViewer() })
            view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            fileViewerOverlay = overlay
        }
        ZettyLog.viewer.log("""
            present: overlay=\(reused ? "reused" : "new") \
            inWindow=\(overlay.window != nil) \
            hostSize=\(NSStringFromSize(self.view.bounds.size))
            """)
        overlay.show(loaded, projectRoot: projectRoot)
    }

    func dismissFileViewer() {
        fileViewerOverlay?.removeFromSuperview()
        fileViewerOverlay = nil
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
        // Space.id is a UUID minted at creation and never user-editable, so
        // `workspace.spaces` can't hold two entries sharing one — safe to build
        // with the trapping initializer. (A clone's own spaceID resolution,
        // which DOES need to tolerate a hand-edited/duplicated rootPath, lives
        // in `WorkspaceModel.effectiveSpaceID(of:)` below.)
        let spaceNames = Dictionary(uniqueKeysWithValues: workspace.spaces.map { ($0.id, $0.name) })
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
                        isFocused: isActiveTab && surface.id == tree.focusedSurfaceID,
                        live: registry.isLive(surface.id)
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
            let effectiveSpaceID = workspace.effectiveSpaceID(of: project)
            return StatusSnapshot.Project(name: project.name, isActive: isActiveProject,
                                         hibernated: project.isHibernated,
                                         space: effectiveSpaceID.flatMap { spaceNames[$0] }, tabs: tabs)
        }
        return StatusSnapshot(projects: projects,
                               spaces: workspace.spaces.map { .init(name: $0.name, collapsed: $0.isCollapsed) })
    }

    /// Injects text/keys into the targeted pane (CLI `send`). Returns an error
    /// message, or nil on success.
    func sendInput(target: PaneSelector, text: String?, enter: Bool, keys: [String]) -> String? {
        do {
            let pane = try target.resolve(in: statusSnapshot().panes)
            guard let location = locate(shortID: pane.id),
                  let surface = surface(withShortID: pane.id) else {
                return "pane \(pane.id) not found"
            }
            // Validate the payload BEFORE anything with side effects, so a typo'd
            // key name can't wake a project on its way to an error.
            var payload = text ?? ""
            for key in keys {
                guard let sequence = KeyNotation.encode(key) else { return "unknown key \"\(key)\"" }
                payload += sequence
            }
            if enter { payload += "\r" }
            guard !payload.isEmpty else { return "nothing to send" }

            switch ensurePaneIsLive(at: location) {
            case .alreadyLive:
                guard registry.sendText(payload, to: surface) else {
                    return "pane \(pane.id) has no live terminal"
                }
            case .spawned:
                // The shell was just created and isn't reading its pty yet, so an
                // immediate write is swallowed. Deliver on the same grace period
                // startup commands use — exit 0 here means "queued".
                deliverAfterSpawn(payload, to: surface.id)
            case .unavailable:
                return "pane \(pane.id) could not be made live"
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
        let project = workspace.projects[targetIndex]
        let wasHibernated = project.isHibernated
        let tabList = project.tabList
        let newPaneID = tabList.newBackgroundTab()
        let newTabIndex = tabList.trees.count - 1

        if focus {
            tabList.select(index: newTabIndex)
            if wasHibernated || targetIndex != workspace.activeIndex {
                revealProject(at: targetIndex)          // wakes or selects; either rebuilds
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
            spawnIfProjectDormant((targetIndex, newTabIndex, newPaneID))
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
    func addProject(path: String, name: String?, space: String?, focus: Bool = false) -> Result<String, ControlError> {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.protocolError("no such directory: \(root)"))
        }
        if let existing = workspace.projects.first(where: { $0.rootPath == root }) {
            return .failure(.protocolError("project \"\(existing.name)\" already uses \(root)"))
        }
        var spaceID: UUID?
        if let space {
            guard let found = workspace.space(named: space) else {
                return .failure(.protocolError("no Space named \"\(space)\""))
            }
            spaceID = found.id
        }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let project = addProjectFromURL(
            URL(fileURLWithPath: root), name: (trimmed?.isEmpty ?? true) ? nil : trimmed, activate: focus)
        if let spaceID, let index = workspace.projects.firstIndex(where: { $0.id == project.id }) {
            // Discard is safe: `space` was already resolved to a real Space above,
            // and `project` was just created as an ordinary project (never Home,
            // scratch, or a clone), so `assign` cannot refuse it here.
            _ = workspace.assign(projectAt: index, to: spaceID)
        }
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
        // Legacy pre-Home workspaces can have ORDINARY projects rooted at ~ —
        // the isHome flag alone doesn't catch those, and cloning the home
        // directory copies the whole account (TCC-protected ~/Library, GBs).
        guard CloneSupport.isCloneableSource(path: source.rootPath, home: NSHomeDirectory()) else {
            return .failure(.protocolError(
                "\"\(source.name)\" is rooted at your home directory — cloning it would copy your entire account. Clone a project folder instead."))
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
    /// switches to it and spawns its pane. Layout templates deliberately do
    /// NOT apply — the clone carries the source's real files. `startupCommand`
    /// (the clone sheet's "Open with" agent) injects into the first pane once
    /// it spawns, via the same path the new-pane agent chooser uses.
    func registerClone(plan: ClonePlan, outcome: CloneRunner.Outcome, focus: Bool,
                       startupCommand: String? = nil) -> Result<String, ControlError> {
        let project = workspace.addCloneProject(
            name: plan.projectName, rootPath: plan.targetPath,
            cloneSource: plan.sourceRootPath, makeActive: focus)
        // Resolve the first pane BEFORE the rebuild spawns it, so the agent
        // command is pending by the time the surface appears.
        let firstSurface = project.tabList.activeTree.focusedSurface
            ?? project.tabList.activeTree.layout.surfaces.first
        if let startupCommand, let firstSurface {
            pendingStartupCommands[firstSurface.id] = startupCommand
        }
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
            presentNotice(
                title: "Clone created, but it's still on the source's branch",
                detail: "git switch -c \(plan.branchName) failed:\n\(branchError)"
                    + "\n\nThe clone is usable. Create the branch yourself to keep its"
                    + " commits separate from the source.")
        } else if !outcome.usedCoW {
            // Spec: the fallback is labeled honestly — the user should know this
            // was a full byte copy (slow, real disk), not an instant CoW clone.
            presentNotice(
                title: "Clone created as a full copy",
                detail: "This volume doesn't support copy-on-write, so every file was"
                    + " copied. The clone works the same — it just took longer and uses"
                    + " real disk space.",
                style: .informational)
        }
        guard let firstSurface else {
            return .failure(.noSuchPane("clone added but no pane found"))
        }
        return .success(SessionPersistence.shortID(for: firstSurface.id))
    }

    /// Sheet asking for a clone name (pre-filled with the next free "fork-N")
    /// plus, when the source project has agents set, an "Open with" picker
    /// (defaulting to the first agent) that launches the pick in the clone's
    /// first pane. Clones in the background and focuses the result.
    /// Interactive entry — agents use `zetty clone` instead.
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

        // "Open with" picker — only when the source project has agents set
        // (Project Settings → Agents; the clone inherits those settings).
        // Defaults to the first agent: cloning for a parallel agent is the
        // primary flow, so plain Enter clones AND launches it.
        let agents = (agentsProvider?(source) ?? .disabled).agents
        var openPicker: NSPopUpButton?
        if agents.isEmpty {
            alert.accessoryView = field
        } else {
            let picker = NSPopUpButton(frame: .zero, pullsDown: false)
            for resolved in agents {
                picker.addItem(withTitle: "Open with \(resolved.agent.displayName)")
            }
            picker.addItem(withTitle: "Standard session")
            picker.selectItem(at: 0)
            openPicker = picker
            let stack = NSStackView(views: [field, picker])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.widthAnchor.constraint(equalToConstant: 240),
                picker.widthAnchor.constraint(equalToConstant: 240),
            ])
            stack.setFrameSize(stack.fittingSize)
            alert.accessoryView = stack
        }
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
                // Last picker item is "Standard session" → no command.
                let startupCommand: String? = openPicker.flatMap { picker in
                    let index = picker.indexOfSelectedItem
                    return agents.indices.contains(index) ? agents[index].command : nil
                }
                // Show a "Cloning…" spinner row under the source while the copy
                // runs off-main (it can be slow on a big tree / non-APFS copy).
                let pendingToken = self.beginPendingClone(plan: plan)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let result = CloneRunner.clone(plan)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.endPendingClone(pendingToken)
                        switch result {
                        case .failure(let failure):
                            self.presentCloneError(failure.message)
                        case .success(let outcome):
                            _ = self.registerClone(plan: plan, outcome: outcome, focus: true,
                                                   startupCommand: startupCommand)
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
            return addProject(path: path, name: name, space: nil, focus: focus)
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

    enum UpdateClonePlan {
        case ready(cloneRoot: String, sourceRoot: String)
        case failed(String)
    }

    /// Main-thread planning for `update-clone`: resolve the named clone and
    /// confirm it is a clone whose source directory still exists.
    func planUpdateClone(name: String) -> UpdateClonePlan {
        let needle = name.lowercased()
        let matches = workspace.projects.filter { $0.name.lowercased() == needle }
        guard let clone = matches.first else {
            return .failed("no project named \"\(name)\"")
        }
        guard matches.count == 1 else {
            return .failed("\(matches.count) projects named \"\(name)\" — update it via the sidebar")
        }
        guard let sourceRoot = clone.cloneSource else {
            return .failed("\"\(clone.name)\" is not a clone")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceRoot, isDirectory: &isDir), isDir.boolValue else {
            return .failed("the source directory is gone (\(sourceRoot)) — cannot update")
        }
        return .ready(cloneRoot: clone.rootPath, sourceRoot: sourceRoot)
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
            // A split in a dormant project exists only in the model, so spawn the
            // new pane before returning its id. A no-op when the `focus` branch
            // above already woke the project.
            spawnIfProjectDormant((location.projectIndex, location.tabIndex, newID))
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
                tabList.select(index: newTabIndex)
                revealProject(at: location.projectIndex)
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
                // Dormant project: spawn the moved pane so its id is usable.
                spawnIfProjectDormant((location.projectIndex, newTabIndex, movedID))
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
            // The only verb that refuses a dormant pane instead of waking it:
            // hibernating killed the zmx session this reads from, so waking would
            // spawn a fresh shell with empty history — a side effect in exchange
            // for nothing. Say that, rather than let zmx fail obscurely.
            if let project = workspace.project(containing: surface.id), project.isHibernated {
                return .failure(.noSuchPane(
                    "project \"\(project.name)\" is hibernated — its sessions were freed, "
                    + "so there is no captured output; `zetty wake \"\(project.name)\"` starts fresh shells"))
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

    /// Whether a pane could be made live, and at what cost to the caller.
    enum PaneLiveness {
        /// The pane already had a terminal behind it; nothing was disturbed.
        case alreadyLive
        /// A terminal was created — a brand-new shell that isn't reading its pty
        /// yet, so input must wait out `spawnGracePeriod`.
        case spawned
        /// No terminal could be created (the pane or its tab went away).
        case unavailable
    }

    /// Brings the project at `index` on screen, waking it first when dormant.
    /// The single expression of "showing a project means showing a *live* one" —
    /// `selectProject` alone renders a hibernated project's placeholder, which is
    /// what used to make `focus` on a dormant pane a no-op.
    private func revealProject(at index: Int) {
        guard workspace.projects.indices.contains(index) else { return }
        let project = workspace.projects[index]
        if project.isHibernated {
            wakeProject(project)                        // selects + rebuilds
        } else if index != workspace.activeIndex {
            selectProject(at: index)
        }
    }

    /// Spawns `location`'s pane, but only when its project is hibernated — the
    /// case where the id a background verb hands back would otherwise name a pane
    /// that can never accept input.
    ///
    /// A never-viewed pane in an *awake* project is deliberately left lazy: that
    /// is the documented background contract, and `send` materializes it on
    /// demand anyway. So this is narrowly about dormancy, not about liveness in
    /// general.
    private func spawnIfProjectDormant(_ location: (projectIndex: Int, tabIndex: Int, surfaceID: UUID)) {
        guard workspace.projects.indices.contains(location.projectIndex),
              workspace.projects[location.projectIndex].isHibernated else { return }
        ensurePaneIsLive(at: location)
    }

    /// Makes the pane at `location` live so it can accept input, without
    /// permanently disturbing what the user is looking at.
    ///
    /// A pane has no terminal behind it in two cases: its project is hibernated
    /// (panes deliberately freed), or its tab has never been viewed (shells
    /// spawn lazily on first view). Both need the same remedy, because a surface
    /// is only ever created while its project *and* tab are the visible ones —
    /// so this wakes the project when needed, transiently reveals the pane, then
    /// restores the caller's previous selection.
    ///
    /// Switching away does not undo the spawn: once created, a pair survives in
    /// the registry because `allSurfaceIDs` covers every awake project, so
    /// `prune` spares it. That is what lets a CLI verb hand back a pane that is
    /// genuinely live without yanking the user's view — the same
    /// select-then-restore shape `closePane` uses.
    @discardableResult
    private func ensurePaneIsLive(at location: (projectIndex: Int, tabIndex: Int, surfaceID: UUID)) -> PaneLiveness {
        if registry.isLive(location.surfaceID) { return .alreadyLive }
        guard workspace.projects.indices.contains(location.projectIndex) else { return .unavailable }
        let project = workspace.projects[location.projectIndex]
        guard project.tabList.trees.indices.contains(location.tabIndex) else { return .unavailable }

        let previousProjectID = workspace.activeProject.id
        let previousTabIndex = project.tabList.activeIndex

        revealProject(at: location.projectIndex)
        if project.tabList.activeIndex != location.tabIndex {
            project.tabList.select(index: location.tabIndex)
            refreshTabBar()
            rebuildSurfaceNodeView()                    // creates the pane's terminal view
        }
        let liveness: PaneLiveness = registry.isLive(location.surfaceID) ? .spawned : .unavailable

        // Put back what the user was looking at. The surface just created stays
        // live across the switch (see above).
        if project.tabList.activeIndex != previousTabIndex,
           project.tabList.trees.indices.contains(previousTabIndex) {
            project.tabList.select(index: previousTabIndex)
        }
        if let back = workspace.projects.firstIndex(where: { $0.id == previousProjectID }),
           back != workspace.activeIndex {
            selectProject(at: back)                     // rebuilds + restores first responder
        } else {
            refreshTabBar()
            rebuildSurfaceNodeView()
            if let focused = focusedTerminalView() { view.window?.makeFirstResponder(focused) }
        }
        refreshSidebar()
        return liveness
    }

    /// Makes the pane at `location` the focused pane of the visible tab. Wakes a
    /// hibernated project first — unlike the background verbs, `focus` exists to
    /// switch the view, so it wakes and *stays* rather than restoring.
    private func focusPane(at location: (projectIndex: Int, tabIndex: Int, surfaceID: UUID)) {
        revealProject(at: location.projectIndex)
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

    /// Title shared by the tab bar, sidebar tab rows, and hidden-window menu.
    private func tabDisplayTitle(for tree: PaneTree, at index: Int) -> String {
        let focusedSurface = tree.focusedSurface
        let workingDir = focusedSurface.flatMap { registry.workingDirectory(for: $0) }
            ?? focusedSurface?.workingDir
        let icon = agentIcon(for: focusedSurface)
        return TabTitle.display(
            manualTitle: tree.manualTitle,
            agentName: icon == nil ? agentDisplayName(for: focusedSurface) : nil,
            focusedSurfaceTitle: displayTitle(for: focusedSurface),
            workingDir: workingDir,
            index: index
        )
    }

    /// Current awake workspace destinations for the menu-bar handoff. Built on
    /// demand because the control CLI can change projects and tabs while the
    /// main window is hidden.
    func menuBarSnapshot() -> [MenuBarProjectSnapshot] {
        workspace.projects.enumerated().compactMap { projectIndex, project -> MenuBarProjectSnapshot? in
            guard !project.isHibernated else { return nil }
            let isActiveProject = projectIndex == workspace.activeIndex
            let tabs = project.tabList.trees.enumerated().map { tabIndex, tree in
                let status = tree.focusedSurface.flatMap {
                    agentDetector.state(for: $0.id).status
                }
                return MenuBarTabSnapshot(
                    index: tabIndex,
                    title: tabDisplayTitle(for: tree, at: tabIndex),
                    status: status,
                    isActive: isActiveProject && tabIndex == project.tabList.activeIndex
                )
            }
            let status = tabs.compactMap(\.status).max {
                Self.severity($0) < Self.severity($1)
            }
            return MenuBarProjectSnapshot(
                id: project.id,
                title: project.name,
                tabs: tabs,
                status: status,
                isActive: isActiveProject
            )
        }
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
            icons.append(agentIcon(for: tree.focusedSurface))
            return tabDisplayTitle(for: tree, at: idx)
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
        var sidebarProjects: [SidebarProject] = workspace.projects.map { project in
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
                    // Same rule as the tab bar: a logo replaces the name prefix.
                    let icon = agentIcon(for: tree.focusedSurface)
                    tabIcons.append(icon)
                    return tabDisplayTitle(for: tree, at: idx)
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
                },
                isPendingClone: false,
                spaceID: project.spaceID
            )
        }
        // Splice in "Cloning…" placeholder rows: each nests under its source via
        // cloneSourceIndex (falls back to a standalone row when the source isn't
        // a visible top-level project, same as an orphan clone).
        for pending in pendingClones {
            let sourceIndex = workspace.projects.firstIndex {
                $0.rootPath == pending.sourceRootPath && $0.cloneSource == nil
            }
            sidebarProjects.append(SidebarProject(
                name: pending.displayName,
                isPinned: false, tabTitles: [], tabStatuses: [], tabIcons: [],
                icon: nil, status: nil, projectColor: nil, customGlyph: nil,
                isHibernated: false, isScratch: false, isHome: false,
                isClone: true, cloneSourceIndex: sourceIndex, isPendingClone: true,
                spaceID: nil
            ))
        }
        // Identity + appearance only — counts are NOT computed here. They must
        // reflect the sidebar's own (possibly filtered) view of the member
        // list, which only SidebarView.rebuildOutline() has; carrying a second,
        // unfiltered count on SidebarSpace is what let a Space header show
        // stale numbers under a filter.
        let sidebarSpaces: [SidebarSpace] = workspace.spaces.map { space in
            SidebarSpace(
                id: space.id,
                name: space.name,
                color: ZTheme.projectColor(id: space.colorID),
                glyph: space.glyph,
                isCollapsed: space.isCollapsed
            )
        }
        sidebarView?.update(
            projects: sidebarProjects,
            spaces: sidebarSpaces,
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
            presentNotice(title: "Project added, but git init failed",
                          detail: "\(message)\n\nThe folder is a project either way — it"
                              + " just isn't a git repository yet.")
        }
    }

    /// A post-hoc notice: the operation finished, but something about it needs
    /// saying. The title carries the outcome — callers must NOT restate it in
    /// `detail`, and must not reuse one title for unrelated operations (this
    /// said "Project added" for clone failures until it was caught).
    private func presentNotice(title: String, detail: String,
                               style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = detail
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

    // MARK: - Merge Clone to Source

    /// Probes the source's git/remote state off-main, then presents the
    /// "Merge to Source…" chooser (Merge updates / Push to branch, per
    /// availability) and runs the chosen strategy off-main. Nothing is deleted.
    private func confirmMergeToSource(at index: Int) {
        guard workspace.projects.indices.contains(index) else { return }
        let clone = workspace.projects[index]
        guard let sourceRoot = clone.cloneSource else { return }
        let cloneRoot = clone.rootPath
        let cloneName = clone.name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let options = CloneSupport.mergeToSourceOptions(
                isCloneGit: CloneRunner.isGitWorkTree(in: cloneRoot),
                isSourceGit: CloneRunner.isGitWorkTree(in: sourceRoot),
                hasRemote: CloneRunner.hasRemote(in: cloneRoot))
            DispatchQueue.main.async {
                self?.presentMergeToSourceChooser(options: options, cloneRoot: cloneRoot,
                                                  sourceRoot: sourceRoot, cloneName: cloneName)
            }
        }
    }

    private func presentMergeToSourceChooser(options: CloneSupport.MergeToSourceOptions,
                                             cloneRoot: String, sourceRoot: String, cloneName: String) {
        guard options.canMergeUpdates else {
            // Non-git source → the file copy-back diff modal.
            guard let window = view.window else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let changes = FileCopyBackRunner.changes(sourceRoot: sourceRoot, cloneRoot: cloneRoot)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard !changes.isEmpty else {
                        let alert = NSAlert()
                        alert.alertStyle = .informational
                        alert.messageText = "Nothing to bring back"
                        alert.informativeText = "“\(cloneName)” has no changes its source doesn't already have."
                        alert.addButton(withTitle: "OK")
                        alert.beginSheetModal(for: window, completionHandler: nil)
                        return
                    }
                    FileCopyBackSheet.present(cloneName: cloneName, sourceRoot: sourceRoot,
                                              cloneRoot: cloneRoot, changes: changes, on: window) { [weak self] decisions in
                        guard !decisions.isEmpty else { return }
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            let result = FileCopyBackRunner.apply(sourceRoot: sourceRoot,
                                                                  cloneRoot: cloneRoot, decisions: decisions)
                            DispatchQueue.main.async {
                                self?.presentCopyBackResult(result, cloneName: cloneName)
                            }
                        }
                    }
                }
            }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Merge “\(cloneName)” to its source?"
        alert.informativeText = "First updates this clone from the source (resolve any conflicts "
            + "in the clone, then re-run). Then:\n• Merge updates — merges the clone's work into "
            + "the source locally.\n• Push to branch — pushes the clone's branch to the remote so "
            + "you can open a PR."
        alert.addButton(withTitle: "Merge updates")
        if options.canPushToBranch { alert.addButton(withTitle: "Push to branch") }
        alert.addButton(withTitle: "Cancel")

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = CloneRunner.mergeUpdates(cloneRoot: cloneRoot, sourceRoot: sourceRoot)
                    DispatchQueue.main.async { self.presentMergeBackOutcome(outcome, cloneName: cloneName) }
                }
            } else if options.canPushToBranch && response == .alertSecondButtonReturn {
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = CloneRunner.pushBranch(cloneRoot: cloneRoot, sourceRoot: sourceRoot)
                    DispatchQueue.main.async { self.presentPushOutcome(outcome, cloneName: cloneName) }
                }
            }
            // otherwise Cancel — no-op
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: run) }
        else { run(alert.runModal()) }
    }

    private func presentCopyBackResult(_ result: FileCopyBackRunner.ApplyResult, cloneName: String) {
        let alert = NSAlert()
        if result.errors.isEmpty {
            alert.alertStyle = .informational
            alert.messageText = "Brought \(result.applied) file\(result.applied == 1 ? "" : "s") to the source"
            alert.informativeText = "Copied from “\(cloneName)” into its source directory."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Brought \(result.applied) file\(result.applied == 1 ? "" : "s"); \(result.errors.count) failed"
            alert.informativeText = result.errors.joined(separator: "\n")
        }
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    private func presentMergeBackOutcome(_ outcome: CloneRunner.MergeBackOutcome, cloneName: String) {
        let alert = NSAlert()
        switch outcome {
        case .merged(let summary):
            alert.alertStyle = .informational
            alert.messageText = "Merged “\(cloneName)” into its source"
            alert.informativeText = summary
        case .syncConflicts(let files):
            alert.alertStyle = .warning
            alert.messageText = "Resolve conflicts in the clone first"
            alert.informativeText = "Updating the clone from the source left conflicts. Resolve "
                + "these in the clone and commit, then run Merge to Source again:\n"
                + files.joined(separator: "\n")
        case .sourceConflict(let files):
            alert.alertStyle = .warning
            alert.messageText = "Merge conflict in the source — nothing changed"
            alert.informativeText = "The source repo is untouched. Resolve manually. Conflicting "
                + "files:\n" + files.joined(separator: "\n")
        case .refused(let message):
            alert.alertStyle = .warning
            alert.messageText = "Nothing merged"
            alert.informativeText = message
        case .failed(let message):
            alert.alertStyle = .critical
            alert.messageText = "Merge failed"
            alert.informativeText = message
        }
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    private func presentPushOutcome(_ outcome: CloneRunner.PushOutcome, cloneName: String) {
        let alert = NSAlert()
        switch outcome {
        case .pushed(let summary):
            alert.alertStyle = .informational
            alert.messageText = "Pushed “\(cloneName)” to its remote"
            alert.informativeText = summary + "\n\nOpen a pull request to land it in the source."
        case .syncConflicts(let files):
            alert.alertStyle = .warning
            alert.messageText = "Resolve conflicts in the clone first"
            alert.informativeText = "Updating the clone from the source left conflicts. Resolve "
                + "these in the clone and commit, then run Merge to Source again:\n"
                + files.joined(separator: "\n")
        case .refused(let message):
            alert.alertStyle = .warning
            alert.messageText = "Nothing pushed"
            alert.informativeText = message
        case .failed(let message):
            alert.alertStyle = .critical
            alert.messageText = "Push failed"
            alert.informativeText = message
        }
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
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
        // Pluralize off the DEDUPED names actually shown, not `running` — two
        // panes on the same command list once but counted twice, so the old
        // `running.count` read "node. Closing kills the sessions."
        let names = Set(running).sorted()
        let alert = NSAlert()
        alert.messageText = "Close \(what)?"
        alert.informativeText = "Still running: \(names.joined(separator: ", ")). "
            + "Closing stops \(names.count == 1 ? "it" : "them") and discards the output."
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

    /// Switches to the project at `index`, optionally selects one of its tabs,
    /// and focuses the resulting active pane.
    @discardableResult
    func selectProject(at index: Int, tabIndex: Int? = nil) -> Bool {
        guard workspace.projects.indices.contains(index) else { return false }
        if let tabIndex,
           !workspace.projects[index].tabList.trees.indices.contains(tabIndex) {
            return false
        }
        workspace.select(index: index)
        if let tabIndex { workspace.activeTabList.select(index: tabIndex) }
        // Stamp on activation, not just on the 60s tick: a project visited
        // between ticks would otherwise keep no timestamp at all, and
        // `idleFor` would read as 0 forever — so its surfaces would never
        // become eligible for release.
        if workspace.projects.indices.contains(index) {
            lastActiveAt[workspace.projects[index].id] = Date()
        }
        onActiveProjectChanged?()
        refreshTabBar()
        rebuildSurfaceNodeView()
        refreshSidebar()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
        return true
    }

    /// Resolves a menu destination by stable project identity. If a CLI action
    /// hibernated or removed it while the menu was open, the click is ignored.
    @discardableResult
    func selectAwakeProject(id: UUID, tabIndex: Int?) -> Bool {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id }),
              !workspace.projects[index].isHibernated else { return false }
        return selectProject(at: index, tabIndex: tabIndex)
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

    // MARK: - Spaces

    /// Creates a Space. Returns an error message, or nil on success.
    func createSpaceNamed(_ name: String, colorID: String?, glyph: String?) -> String? {
        guard workspace.createSpace(name: name, colorID: colorID, glyph: glyph) != nil else {
            return "a Space named \"\(name)\" already exists (or the name is blank)"
        }
        refreshSidebar()
        onWorkspaceDidChange?()
        return nil
    }

    func renameSpaceNamed(_ name: String, to newName: String) -> String? {
        guard let space = workspace.space(named: name) else {
            return "no Space named \"\(name)\""
        }
        guard workspace.renameSpace(id: space.id, to: newName) else {
            return "a Space named \"\(newName)\" already exists (or the name is blank)"
        }
        refreshSidebar()
        onWorkspaceDidChange?()
        return nil
    }

    func removeSpaceNamed(_ name: String) -> String? {
        guard let space = workspace.space(named: name) else {
            return "no Space named \"\(name)\""
        }
        workspace.removeSpace(id: space.id)
        rebuildSurfaceNodeView()
        refreshSidebar()
        onWorkspaceDidChange?()
        return nil
    }

    /// Moves a project into a Space, or out of every Space when `space` is nil.
    func moveProjectNamed(_ project: String, toSpace space: String?) -> String? {
        let matches = workspace.projects.filter { $0.name.lowercased() == project.lowercased() }
        guard let match = matches.first else { return "no project named \"\(project)\"" }
        guard matches.count == 1 else { return "\(matches.count) projects named \"\(project)\" — use the sidebar" }
        guard let index = workspace.projects.firstIndex(where: { $0 === match }) else {
            return "no project named \"\(project)\""
        }
        var spaceID: UUID?
        if let space {
            guard let found = workspace.space(named: space) else {
                return "no Space named \"\(space)\""
            }
            spaceID = found.id
        }
        guard workspace.assign(projectAt: index, to: spaceID) else {
            return "\"\(project)\" can't belong to a Space (Home, scratch terminals, "
                + "and clones are never members — a clone follows its source)"
        }
        rebuildSurfaceNodeView()
        refreshSidebar()
        onWorkspaceDidChange?()
        return nil
    }

    /// Hibernate every awake project in a Space (CLI `hibernate-space`). Reuses
    /// the existing per-project hibernate entry point, so session teardown and
    /// `reconcileSessions()` keep their usual behavior.
    func hibernateSpaceNamed(_ name: String) -> String? {
        guard let space = workspace.space(named: name) else {
            return "no Space named \"\(name)\""
        }
        for project in workspace.projects(inSpace: space.id) where !project.isHibernated {
            hibernateProject(project, confirmIfBusy: false)
        }
        return nil
    }

    /// Wake every hibernated project in a Space (CLI `wake-space`).
    func wakeSpaceNamed(_ name: String) -> String? {
        guard let space = workspace.space(named: name) else {
            return "no Space named \"\(name)\""
        }
        for project in workspace.projects(inSpace: space.id) where project.isHibernated {
            wakeProject(project)
        }
        return nil
    }

    /// Sidebar drag/menu path: assign a project to a Space (nil = ungroup).
    func assignProject(at index: Int, to spaceID: UUID?) {
        guard workspace.assign(projectAt: index, to: spaceID) else { return }
        rebuildSurfaceNodeView()
        refreshSidebar()
        onWorkspaceDidChange?()
    }

    /// Sidebar header drag: reorder the Spaces themselves.
    func moveSpace(from: Int, to: Int) {
        workspace.moveSpace(from: from, to: to)
        rebuildSurfaceNodeView()
        refreshSidebar()
        onWorkspaceDidChange?()
    }

    /// Fold/unfold a Space. Persisted, so it goes through the model rather than
    /// living in the view like the Hibernating section's collapse state.
    func setSpaceCollapsed(_ id: UUID, _ collapsed: Bool) {
        workspace.setSpaceCollapsed(id: id, collapsed)
        refreshSidebar()
        onWorkspaceDidChange?()
    }

    /// "New Space…" from a project row's "Move to Space ▸" submenu — presents
    /// `SpaceSheet` with an empty name, creates the Space on save, and when
    /// `project` was passed (always true for this menu path) files that
    /// project into the new Space in the same step. A duplicate/blank name
    /// surfaces an alert rather than failing silently.
    ///
    /// Takes the `ProjectRuntime` itself rather than an index: the sheet is
    /// async, and control-socket handlers run on main and aren't blocked by a
    /// sheet-modal, so the workspace can be restructured while it's open (a
    /// background clone landing, `zetty remove-project`, a re-pin). An index
    /// captured before the sheet opened could silently name a different
    /// project by the time the completion handler runs; identity can't.
    func promptNewSpace(assigning project: ProjectRuntime?) {
        guard let window = view.window else { return }
        SpaceSheet.present(over: window, name: "", colorID: nil, glyph: nil) { [weak self] name, colorID, glyph in
            guard let self else { return }
            if let error = self.createSpaceNamed(name, colorID: colorID, glyph: glyph) {
                self.presentSpaceError(error, title: "Couldn\u{2019}t create Space")
                return
            }
            // Re-resolve the project's CURRENT index by identity — it may have
            // moved (or vanished) while the sheet was open. If it's gone,
            // still create the Space; just skip filing the wrong project.
            if let project, let projectIndex = self.workspace.projects.firstIndex(where: { $0 === project }),
               let space = self.workspace.space(named: name) {
                self.assignProject(at: projectIndex, to: space.id)
            }
        }
    }

    /// "Rename…" and "Edit Space…" both land here — the sheet's name field
    /// covers renaming, so there is only one editor. A duplicate/blank name
    /// surfaces an alert and leaves the Space untouched (including its color
    /// and glyph, so a rejected rename never silently applies the rest).
    func promptEditSpace(_ id: UUID) {
        guard let window = view.window,
              let space = workspace.spaces.first(where: { $0.id == id }) else { return }
        SpaceSheet.present(over: window, name: space.name, colorID: space.colorID, glyph: space.glyph) {
            [weak self] name, colorID, glyph in
            guard let self else { return }
            if name != space.name, let error = self.renameSpaceNamed(space.name, to: name) {
                self.presentSpaceError(error, title: "Couldn\u{2019}t rename Space")
                return
            }
            self.workspace.updateSpace(id: id, colorID: colorID, glyph: glyph)
            self.refreshSidebar()
            self.onWorkspaceDidChange?()
        }
    }

    /// "Delete Space…" — confirms first, stating plainly that member projects
    /// are KEPT and only the grouping is removed (the model's actual
    /// behavior, per `WorkspaceModel.removeSpace`).
    func confirmDeleteSpace(_ id: UUID) {
        guard let window = view.window,
              let space = workspace.spaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Space \u{201c}\(space.name)\u{201d}?"
        alert.informativeText = "Its projects are kept — only the Space grouping is removed;"
            + " they fall back to Pinned/Projects."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let spaceName = space.name
        let confirm: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            _ = self?.removeSpaceNamed(spaceName)
        }
        alert.beginSheetModal(for: window, completionHandler: confirm)
    }

    private func presentSpaceError(_ text: String, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
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

        // Every structural change funnels through here, which makes it the one
        // reliable place to notice that a pane (and therefore a session) is
        // gone. Debounced, so a burst costs one `zmx list`. Wiring it here
        // rather than at each close site is deliberate: the two GUI close paths
        // were the ones that forgot, and left rogue shells behind.
        setNeedsSessionReconcile()
        // Any layout/tab change invalidates an active copy-mode session (its
        // selection and viewport-relative cursor no longer mean anything).
        exitCopyModeIfActive()
        // Same reasoning for the hover underline, which is parented to a
        // surface view that's about to be torn down.
        pathHover.reset()
        // File trees are recreated per rebuild; their FSEvents streams must not
        // outlive the views that own them.
        for leaf in rootContentView?.leafContainers() ?? [] { leaf.stopFileTreeWatching() }

        rootContentView?.removeFromSuperview()
        rootContentView = nil
        placeholderView?.removeFromSuperview()
        placeholderView = nil
        cloneWarningBanner?.removeFromSuperview()
        cloneWarningBanner = nil

        // Pin below the tab bar (28 pt), or to the top if there is no tab bar yet;
        // and above the status bar (if present), else to the container bottom.
        var topGuide: NSLayoutYAxisAnchor = tabBarView?.bottomAnchor ?? container.topAnchor
        let bottomGuide = statusBarView?.topAnchor ?? container.bottomAnchor

        // A clone's working copy is disposable — slot a caution strip below the
        // tab bar and push the content (terminal OR hibernation placeholder)
        // down beneath it.
        if workspace.activeProject.cloneSource != nil {
            let clone = workspace.activeProject
            // Git clones expose the merge-guide button; non-git clones don't.
            let cloneGitDir = (clone.rootPath as NSString).appendingPathComponent(".git")
            let isGitClone = FileManager.default.fileExists(atPath: cloneGitDir)
            // Cheap, display-derived fallback only — the real branch is
            // resolved from the repo lazily when the popover opens (a
            // synchronous git spawn here would run on every chrome rebuild).
            let fallbackBranch = isGitClone
                ? (clone.name.split(separator: "/").last.map(String.init) ?? clone.name)
                : nil
            let banner = CloneWarningBanner(
                fallbackBranch: fallbackBranch,
                clonePath: isGitClone ? clone.rootPath : nil,
                sourcePath: isGitClone ? clone.cloneSource : nil)
            banner.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: topGuide),
                banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                banner.heightAnchor.constraint(equalToConstant: CloneWarningBanner.height),
            ])
            cloneWarningBanner = banner
            topGuide = banner.bottomAnchor
        }

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
            registry.prune(keeping: Set(allSurfaceIDs)) // free the frozen surfaces
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
            paneActions: PaneActionWiring(
                onClose: { [weak self] id in self?.closePane(surfaceID: id) },
                onBreak: { [weak self] id in self?.breakPane(surfaceID: id) },
                onSplit: { [weak self] id, direction in
                    self?.splitPane(surfaceID: id, direction: direction)
                },
                onScrollToBottom: { [weak self] id in self?.scrollToBottom(surfaceID: id) }
            ),
            onRatioChange: { [weak self] path, ratio in
                // Write the dragged divider position back to the model (no
                // rebuild — the view already shows it) and autosave.
                guard let self else { return }
                if self.paneTree.layout.setRatio(at: path, to: ratio) {
                    self.onWorkspaceDidChange?()
                }
            },
            fileTree: FileTreeWiring(
                settings: { [weak self] in
                    self?.fileTreeSettingsProvider?() ?? FileTreeSettings()
                },
                onToggle: { [weak self] id in self?.toggleFileTree(for: id) },
                onWidthChange: { [weak self] id, width in
                    self?.setFileTreeWidth(width, for: id)
                },
                onPeek: { [weak self] path in
                    _ = self?.presentFileViewer(path: path, line: nil, column: nil)
                },
                onOpenInEditor: { [weak self] path in self?.openInConfiguredEditor(path) }
            )
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

        // Keep any live surface owned by an awake project so background sessions
        // survive project/tab switches. Hibernated projects' surfaces are freed
        // because allSurfaceIDs excludes them.
        registry.prune(keeping: Set(allSurfaceIDs))

        // Trees are recreated per rebuild; root them at their panes' cwds now
        // rather than waiting for the debounce, and let the expansion cache
        // restore whatever the user had open.
        refreshFileTreeRoots()

        // Any structural change (tab add/close, split/close, project add, switch)
        // funnels through here — autosave so disk reflects the current layout.
        onWorkspaceDidChange?()
    }

    // MARK: - File tree

    /// Resolved `zetty-file-tree-*` settings, supplied by `AppDelegate`.
    var fileTreeSettingsProvider: (() -> FileTreeSettings)?

    /// Expansion memory, keyed by absolute root path so `cd`-ing back into a
    /// directory restores the shape the user had open.
    private var fileTreeExpansion = FileTreeExpansionCache()
    private var fileTreeRootWorkItem: DispatchWorkItem?

    /// How long a pane's cwd must settle before its tree re-roots. Agents `cd`
    /// several times a second; a tree that follows every hop is worse than no
    /// tree at all.
    private static let fileTreeRootDebounce: TimeInterval = 0.5

    /// Menu / ⌘↓ action: jumps the focused pane back to the live tail.
    ///
    /// Scrolling up in a long build log and then wanting "back to now" is
    /// otherwise a mouse gesture or a copy-mode round trip. Uses libghostty's
    /// own `scroll_to_bottom` — the same action copy mode calls on exit — so the
    /// viewport rejoins the tail exactly as it does there.
    @objc func scrollToBottom(_ sender: Any?) {
        guard let id = paneTree.focusedSurfaceID else { return }
        scrollToBottom(surfaceID: id)
    }

    /// Surface-addressed variant used by a pane's gutter. Deliberately avoids
    /// changing the first responder, so scrolling an unfocused pane does not
    /// move keyboard focus away from the pane where the user is typing.
    private func scrollToBottom(surfaceID: UUID) {
        guard let view = registry.appTerminalView(for: surfaceID) else { return }
        view.performBindingAction("scroll_to_bottom")
    }

    /// Menu / ⇧⌘F action: toggles the focused pane's file tree.
    ///
    /// A native key equivalent rather than a prefix binding because the engine
    /// has no direct-binding table — in normal mode it only tests for the prefix
    /// chord and passes everything else through. `Ctrl+B e` remains the
    /// rebindable route.
    @objc func toggleFileTree(_ sender: Any?) {
        guard let id = paneTree.focusedSurfaceID else { return }
        toggleFileTree(for: id)
    }

    /// Shows or hides a pane's file tree, persisting the choice.
    ///
    /// Routes through `rebuildSurfaceNodeView()` — the established path for a
    /// structural change — after banking the outgoing tree's expansion state, so
    /// toggling off and on again doesn't lose the user's place.
    func toggleFileTree(for surfaceID: UUID) {
        if let leaf = rootContentView?.leafContainers().first(where: { $0.surfaceID == surfaceID }),
           let root = leaf.fileTreeCurrentRoot {
            fileTreeExpansion.record(root: root, expanded: leaf.fileTreeExpandedDirectories)
        }
        guard paneTree.layout.update(surfaceID: surfaceID, { $0.fileTreeVisible.toggle() })
        else { return }
        rebuildSurfaceNodeView()
    }

    /// Records a dragged width. Deliberately does NOT rebuild — a resize is not a
    /// structural change, and rebuilding mid-drag would fight the gesture.
    func setFileTreeWidth(_ width: Double, for surfaceID: UUID) {
        guard paneTree.layout.update(surfaceID: surfaceID, { $0.fileTreeWidth = width })
        else { return }
        onWorkspaceDidChange?()
    }

    /// Re-roots every visible tree at its pane's current cwd, debounced by
    /// `fileTreeRootDebounce`.
    func setNeedsFileTreeRootRefresh() {
        fileTreeRootWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshFileTreeRoots() }
        fileTreeRootWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fileTreeRootDebounce,
                                      execute: work)
    }

    func refreshFileTreeRoots() {
        for leaf in rootContentView?.leafContainers() ?? [] where leaf.hasFileTree {
            guard let surface = paneTree.layout.surfaces.first(where: { $0.id == leaf.surfaceID })
            else { continue }
            let root = PaneCwdStore.read(leaf.surfaceID) ?? surface.workingDir
            guard root != leaf.fileTreeCurrentRoot else { continue }
            // Bank what was open under the OLD root before moving.
            if let previous = leaf.fileTreeCurrentRoot {
                fileTreeExpansion.record(root: previous,
                                         expanded: leaf.fileTreeExpandedDirectories)
            }
            leaf.setFileTreeRoot(root, expanding: fileTreeExpansion.expanded(for: root))
        }
    }

    /// Opens `path` in the configured editor, falling back to the system default
    /// when no editor is configured or it has no line-addressing scheme.
    func openInConfiguredEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let configured = editorProvider?()?.trimmingCharacters(in: .whitespaces)
        guard let name = configured, !name.isEmpty, let editor = EditorCatalog.resolve(name) else {
            if !NSWorkspace.shared.open(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return
        }
        if let deepLink = EditorCatalog.openURL(for: editor, file: path, line: nil, column: nil) {
            NSWorkspace.shared.open(deepLink)
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: editor,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Helpers

    /// Returns the `NSView` for the currently focused surface, if any.
    /// Declared `internal` so the `PaneActions` extension (same module) can call it.
    func focusedTerminalView() -> NSView? {
        guard let surface = paneTree.focusedSurface else { return nil }
        return registry.terminalView(for: surface)
    }

    /// Returns the `NSView` for `surfaceID` if that surface is still in the
    /// active tab. Declared `internal` for the `PaneActions` extension.
    func terminalView(forSurface surfaceID: UUID) -> NSView? {
        guard let surface = paneTree.layout.surfaces.first(where: { $0.id == surfaceID })
        else { return nil }
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
