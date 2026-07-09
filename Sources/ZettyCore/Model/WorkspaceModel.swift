import Foundation

public final class ProjectRuntime {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public var isPinned: Bool
    /// When true, the project's sessions/processes/panes are freed; only its
    /// layout remains. Waking re-spawns fresh shells.
    public var isHibernated: Bool
    /// A project-less, ephemeral "scratch" terminal: rooted at home, shown in
    /// the Scratch sidebar section, never persisted, and its panes never use
    /// zmx. Not pinnable or hibernatable.
    public let isScratch: Bool
    public let tabList: TabList

    public init(id: UUID = UUID(), name: String, rootPath: String,
                isPinned: Bool = false, isHibernated: Bool = false,
                isScratch: Bool = false, tabList: TabList? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isPinned = isPinned
        self.isHibernated = isHibernated
        self.isScratch = isScratch
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
        regroup()
    }

    public var activeProject: ProjectRuntime { projects[activeIndex] }
    public var activeTabList: TabList { projects[activeIndex].tabList }

    @discardableResult
    /// Adds a project. `makeActive` (default true) switches to it; pass false to
    /// add it in the background, leaving the current active project selected.
    /// A new (unpinned) project lands at the bottom of its group.
    public func addProject(name: String, rootPath: String, makeActive: Bool = true) -> ProjectRuntime {
        let p = ProjectRuntime(name: name, rootPath: rootPath)
        projects.append(p)
        if makeActive { activeIndex = projects.count - 1 }
        regroup()   // preserves the active project by identity
        return p
    }

    /// Adds a project-less scratch terminal (rooted at home). It is unpinned (so
    /// it lands in the Scratch section) and ephemeral. `makeActive` (default
    /// true) switches to it; pass false to add it in the background.
    @discardableResult
    public func addScratchProject(makeActive: Bool = true) -> ProjectRuntime {
        let home = NSHomeDirectory()
        let p = ProjectRuntime(name: nextScratchName(), rootPath: home, isScratch: true)
        projects.append(p)
        if makeActive { activeIndex = projects.count - 1 }
        regroup()   // keeps it after the pinned group
        return p
    }

    /// A unique scratch name: "scratch", then "scratch 2", "scratch 3", …
    private func nextScratchName() -> String {
        let existing = Set(projects.filter(\.isScratch).map(\.name))
        if !existing.contains("scratch") { return "scratch" }
        var n = 2
        while existing.contains("scratch \(n)") { n += 1 }
        return "scratch \(n)"
    }

    /// Removes every scratch terminal at once, re-pointing `activeIndex` at the
    /// first pinned project (or the first project if none are pinned). No-op if
    /// there are no scratch projects, or if removing them would leave none.
    public func removeScratchProjects() {
        guard projects.contains(where: \.isScratch) else { return }
        let survivors = projects.filter { !$0.isScratch }
        guard !survivors.isEmpty else { return }
        projects = survivors
        activeIndex = projects.firstIndex(where: \.isPinned) ?? 0
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
        regroup()   // pinning drops the project at the bottom of its new group
    }

    /// Moves a project from one position to another within the same section.
    /// The active project is preserved by identity. Callers must keep the move
    /// within one pin-group (Pinned ↔ Pinned, unpinned ↔ unpinned); a cross-group
    /// move is rejected so the pinned-first invariant can't be broken.
    public func moveProject(from: Int, to: Int) {
        guard projects.indices.contains(from), projects.indices.contains(to),
              from != to,
              projects[from].isPinned == projects[to].isPinned else { return }
        let activeID = projects[activeIndex].id
        let moved = projects.remove(at: from)
        projects.insert(moved, at: to)
        activeIndex = projects.firstIndex { $0.id == activeID } ?? 0
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

    /// Renames a project in place. Order is manual, so renaming never moves the
    /// project (unlike the old alphabetical sort).
    public func rename(projectAt index: Int, to newName: String) {
        guard projects.indices.contains(index) else { return }
        projects[index].name = newName
    }

    /// Enforces the only ordering invariant: pinned projects come before
    /// unpinned ones. Within each group the existing relative order is preserved
    /// (manual order), because `filter` is stable. The active project is
    /// preserved by identity so `activeIndex` keeps pointing at the same project.
    private func regroup() {
        guard !projects.isEmpty else { return }
        let activeID = projects[activeIndex].id
        projects = projects.filter(\.isPinned) + projects.filter { !$0.isPinned }
        activeIndex = projects.firstIndex { $0.id == activeID } ?? 0
    }
}
