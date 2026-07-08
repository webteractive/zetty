import Foundation

/// Maps between the live `TabList`/`PaneTree` model and the persisted `Workspace`.
///
/// All tabs are wrapped in a single default `Project`/`Session` for now;
/// richer project modeling is deferred to a later slice.
public enum SessionSnapshot {

    // MARK: - Constants

    private static let defaultProjectName = "default"
    private static let defaultProjectRootPath = NSHomeDirectory()
    private static let defaultSessionTitle  = "default"

    // MARK: - TabList → Workspace

    /// Converts a `TabList` into a `Workspace` ready for persistence.
    ///
    /// Each tab's `PaneTree.layout` becomes a `Tab(title:layout:)`.
    /// All tabs are grouped under one default `Project` → `Session`.
    public static func workspace(from tabList: TabList) -> Workspace {
        let tabs = tabList.trees.map { tree in
            Tab(title: tree.manualTitle ?? "", layout: tree.layout)
        }
        let session = Session(title: defaultSessionTitle, tabs: tabs)
        let project = Project(
            name: defaultProjectName,
            rootPath: defaultProjectRootPath,
            preserveSessions: true,
            sessions: [session]
        )
        return Workspace(projects: [project])
    }

    // MARK: - Workspace → [PaneTree]

    /// Converts a persisted `Workspace` back into an array of `PaneTree`s.
    ///
    /// Each `Tab.layout` in the first project's first session becomes a
    /// `PaneTree(layout:focusedSurfaceID:)` with focus set to the first surface.
    ///
    /// Returns `[]` when the workspace has no projects, sessions, or tabs
    /// (the caller falls back to a fresh single-tab layout).
    public static func paneTrees(from workspace: Workspace) -> [PaneTree] {
        guard
            let project = workspace.projects.first,
            let session = project.sessions.first,
            !session.tabs.isEmpty
        else { return [] }

        return paneTrees(from: session.tabs)
    }

    // MARK: - WorkspaceModel → Workspace

    /// Converts a live `WorkspaceModel` into a `Workspace` ready for persistence.
    ///
    /// Each `ProjectRuntime` becomes a `Project` with a single default session
    /// whose tabs are derived from the project's `tabList.trees`. The model's
    /// active-project index, each project's active tab, and each tab's focused
    /// pane are persisted so restoration reopens exactly where the user left off.
    public static func workspace(from model: WorkspaceModel) -> Workspace {
        // Scratch projects are ephemeral — never persisted. Filtering them here
        // also means `activeProjectIndex` must be remapped to the saved list.
        let persistable = model.projects.enumerated().filter { !$0.element.isScratch }
        let projects = persistable.enumerated().map { savedIndex, entry in
            let runtime = entry.element
            let tabs = runtime.tabList.trees.map { tree in
                Tab(title: tree.manualTitle ?? "",
                    layout: tree.layout,
                    focusedSurfaceID: tree.focusedSurfaceID)
            }
            return Project(
                name: runtime.name,
                rootPath: runtime.rootPath,
                isPinned: runtime.isPinned,
                sortOrder: savedIndex,
                isHibernated: runtime.isHibernated,
                sessions: [Session(title: "main", tabs: tabs, activeTabIndex: runtime.tabList.activeIndex)]
            )
        }
        // Map the model's active index into the filtered list; fall back to 0
        // when the active project is a scratch one (not saved).
        let activeIndex = persistable.firstIndex { $0.offset == model.activeIndex }.map {
            persistable.distance(from: persistable.startIndex, to: $0)
        } ?? 0
        return Workspace(projects: projects, activeProjectIndex: activeIndex)
    }

    // MARK: - Workspace → [ProjectRuntime]

    /// Converts a persisted `Workspace` back into an array of `ProjectRuntime`s.
    ///
    /// Each `Project` yields a `ProjectRuntime` whose `TabList` is restored from
    /// the project's first session's tabs, reselecting the session's active tab.
    /// Returns `[]` for an empty workspace.
    public static func projectRuntimes(from workspace: Workspace) -> [ProjectRuntime] {
        // Restore in persisted manual order. `workspace(from:)` writes `sortOrder`
        // as the final array position, so sorting by it reproduces the order the
        // user last dragged the sidebar into (a stable sort keeps ties as-is).
        let ordered = workspace.projects.sorted { $0.sortOrder < $1.sortOrder }
        return ordered.map { project in
            let session = project.sessions.first
            let trees = paneTrees(from: session?.tabs ?? [])
            let tabList = TabList(restoring: trees, activeIndex: session?.activeTabIndex ?? 0,
                                  defaultWorkingDir: project.rootPath)
                ?? TabList(defaultWorkingDir: project.rootPath)
            return ProjectRuntime(
                name: project.name,
                rootPath: project.rootPath,
                isPinned: project.isPinned,
                isHibernated: project.isHibernated,
                tabList: tabList
            )
        }
    }

    // MARK: - Private helpers

    /// Maps an array of persisted `Tab`s to `PaneTree`s, reusing layout → pane
    /// conversion. Focus goes to the tab's saved focused pane when it still
    /// exists in the layout, else the first surface.
    private static func paneTrees(from tabs: [Tab]) -> [PaneTree] {
        tabs.map { tab in
            let surfaceIDs = tab.layout.surfaces.map(\.id)
            let focusID = tab.focusedSurfaceID.flatMap { surfaceIDs.contains($0) ? $0 : nil }
                ?? surfaceIDs.first
            let manualTitle = tab.title.isEmpty ? nil : tab.title
            return PaneTree(layout: tab.layout, focusedSurfaceID: focusID, manualTitle: manualTitle)
        }
    }
}
