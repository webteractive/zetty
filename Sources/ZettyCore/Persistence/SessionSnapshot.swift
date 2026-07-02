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
    /// active-project index is persisted so restoration reactivates it.
    public static func workspace(from model: WorkspaceModel) -> Workspace {
        let projects = model.projects.enumerated().map { index, runtime in
            let tabs = runtime.tabList.trees.map { tree in
                Tab(title: tree.manualTitle ?? "", layout: tree.layout)
            }
            return Project(
                name: runtime.name,
                rootPath: runtime.rootPath,
                isPinned: runtime.isPinned,
                sortOrder: index,
                sessions: [Session(title: "main", tabs: tabs)]
            )
        }
        return Workspace(projects: projects, activeProjectIndex: model.activeIndex)
    }

    // MARK: - Workspace → [ProjectRuntime]

    /// Converts a persisted `Workspace` back into an array of `ProjectRuntime`s.
    ///
    /// Each `Project` yields a `ProjectRuntime` whose `TabList` is restored from
    /// the project's first session's tabs. Returns `[]` for an empty workspace.
    public static func projectRuntimes(from workspace: Workspace) -> [ProjectRuntime] {
        workspace.projects.map { project in
            let tabs = project.sessions.first?.tabs ?? []
            let trees = paneTrees(from: tabs)
            let tabList = TabList(restoring: trees) ?? TabList()
            return ProjectRuntime(
                name: project.name,
                rootPath: project.rootPath,
                isPinned: project.isPinned,
                tabList: tabList
            )
        }
    }

    // MARK: - Private helpers

    /// Maps an array of persisted `Tab`s to `PaneTree`s, reusing layout → pane conversion.
    private static func paneTrees(from tabs: [Tab]) -> [PaneTree] {
        tabs.map { tab in
            let firstID = tab.layout.surfaces.first?.id
            let manualTitle = tab.title.isEmpty ? nil : tab.title
            return PaneTree(layout: tab.layout, focusedSurfaceID: firstID, manualTitle: manualTitle)
        }
    }
}
