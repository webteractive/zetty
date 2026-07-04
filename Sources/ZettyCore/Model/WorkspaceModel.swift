import Foundation

public final class ProjectRuntime {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public var isPinned: Bool
    public let tabList: TabList

    public init(id: UUID = UUID(), name: String, rootPath: String,
                isPinned: Bool = false, tabList: TabList? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isPinned = isPinned
        // Default the project's tab list to open terminals in the project root.
        self.tabList = tabList ?? TabList(defaultWorkingDir: rootPath)
    }
}

/// Ordered list of projects (each owning its own `TabList`) + the active index.
/// Invariant: `projects` is non-empty and `activeIndex` is always valid.
public final class WorkspaceModel {
    public private(set) var projects: [ProjectRuntime]
    public private(set) var activeIndex: Int

    public init() {
        let home = NSHomeDirectory()
        projects = [ProjectRuntime(name: (home as NSString).lastPathComponent, rootPath: home)]
        activeIndex = 0
    }

    public init?(restoring restored: [ProjectRuntime], activeIndex: Int = 0) {
        guard !restored.isEmpty else { return nil }
        projects = restored
        self.activeIndex = min(max(activeIndex, 0), restored.count - 1)
        resort()
    }

    public var activeProject: ProjectRuntime { projects[activeIndex] }
    public var activeTabList: TabList { projects[activeIndex].tabList }

    @discardableResult
    public func addProject(name: String, rootPath: String) -> ProjectRuntime {
        let p = ProjectRuntime(name: name, rootPath: rootPath)
        projects.append(p)
        activeIndex = projects.count - 1
        resort()   // insert into sorted position; active stays on `p`
        return p
    }

    public func removeProject(at index: Int) {
        guard projects.count > 1, projects.indices.contains(index) else { return }
        projects.remove(at: index)
        if activeIndex >= projects.count {
            activeIndex = projects.count - 1
        } else if index < activeIndex {
            activeIndex -= 1
        }
    }

    public func select(index: Int) {
        guard projects.indices.contains(index) else { return }
        activeIndex = index
    }

    public func togglePin(at index: Int) {
        guard projects.indices.contains(index) else { return }
        projects[index].isPinned.toggle()
        resort()   // pinning moves the project into the pinned group
    }

    /// The project owning `surfaceID`, or nil. Used by the app layer to
    /// resolve per-project settings at pane-spawn time.
    public func project(containing surfaceID: UUID) -> ProjectRuntime? {
        projects.first { project in
            project.tabList.trees.contains { tree in
                tree.layout.surfaces.contains { $0.id == surfaceID }
            }
        }
    }

    /// Renames a project and re-sorts (name participates in sidebar order);
    /// the active project is preserved by identity, like `togglePin`.
    public func rename(projectAt index: Int, to newName: String) {
        guard projects.indices.contains(index) else { return }
        projects[index].name = newName
        resort()
    }

    /// Sort order: pinned projects first, then unpinned, each group ordered by
    /// name (case-insensitive). The active project is preserved by identity so
    /// `activeIndex` keeps pointing at the same project after reordering.
    private func resort() {
        guard !projects.isEmpty else { return }
        let activeID = projects[activeIndex].id
        projects.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        activeIndex = projects.firstIndex { $0.id == activeID } ?? 0
    }
}
