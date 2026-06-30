import AppKit
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

    /// The container that wraps the tab-bar + pane area (right side of the split).
    private var contentContainer: NSView?

    /// KVO token for observing `window.firstResponder`.
    private var firstResponderObservation: NSKeyValueObservation?

    // MARK: - View lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSidebarAndContent()
        setupTabBar()
        rebuildSurfaceNodeView()
        refreshSidebar()

        // Refresh the tab bar whenever any live surface reports a title or
        // working-directory change so the active tab's name stays current.
        registry.onTitleChange = { [weak self] _ in
            self?.refreshTabBar()
            self?.refreshSidebar()
        }
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

    // MARK: - Sidebar + content layout setup

    private func setupSidebarAndContent() {
        let sidebar = SidebarView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sidebar)
        view.addSubview(container)

        // Sidebar left edge, fixed width ~200, full height.
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),

            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Add a thin separator line between sidebar and content.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])

        // Wire sidebar callbacks.
        sidebar.onSelectProject = { [weak self] index in
            guard let self else { return }
            self.workspace.select(index: index)
            self.refreshTabBar()
            self.rebuildSurfaceNodeView()
            self.refreshSidebar()
            if let focused = self.focusedTerminalView() {
                self.view.window?.makeFirstResponder(focused)
            }
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

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),
        ])

        self.tabBarView = tabBar
        refreshTabBar()
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
    }

    /// Syncs the sidebar UI state with the workspace.
    func refreshSidebar() {
        let sidebarProjects: [SidebarProject] = workspace.projects.map { project in
            let trees = project.tabList.trees
            // Only provide tab titles when there are 2+ tabs (single-tab projects are plain rows).
            let tabTitles: [String]
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
            } else {
                tabTitles = []
            }
            return SidebarProject(name: project.name, isPinned: project.isPinned, tabTitles: tabTitles)
        }
        sidebarView?.update(
            projects: sidebarProjects,
            activeProject: workspace.activeIndex,
            activeTab: workspace.activeTabList.activeIndex
        )
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

        let newRoot = SurfaceNodeView(
            node: paneTree.layout.root,
            registry: registry,
            focusedSurfaceID: paneTree.focusedSurfaceID
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

        NSLayoutConstraint.activate([
            newRoot.topAnchor.constraint(equalTo: topGuide),
            newRoot.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            newRoot.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            newRoot.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
