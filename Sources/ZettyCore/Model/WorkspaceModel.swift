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
    /// The permanent, non-removable Home project: seeded by default, lives in
    /// its own top sidebar section, can be hibernated but never removed.
    public let isHome: Bool
    /// Canonical rootPath of the project this one was cloned from, or nil for
    /// a normal project. A clone lives in a zetty-owned directory under
    /// ~/.zetty/clones and renders glued to its source in the sidebar.
    public let cloneSource: String?
    public let tabList: TabList

    public init(id: UUID = UUID(), name: String, rootPath: String,
                isPinned: Bool = false, isHibernated: Bool = false,
                isScratch: Bool = false, isHome: Bool = false, cloneSource: String? = nil,
                tabList: TabList? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isPinned = isPinned
        self.isHibernated = isHibernated
        self.isScratch = isScratch
        self.isHome = isHome
        self.cloneSource = cloneSource
        // Default the project's tab list to open terminals in the project root.
        self.tabList = tabList ?? TabList(defaultWorkingDir: rootPath)
    }

    /// The key under which this project's settings are stored. Home uses a
    /// reserved sentinel so it never shares an entry with a user `~` project.
    public var settingsKey: String {
        isHome ? ProjectSettingsStore.homeKey : rootPath
    }
}

/// Ordered list of projects (each owning its own `TabList`) + the active index.
/// Invariant: `projects` is non-empty and `activeIndex` is always valid.
public final class WorkspaceModel {
    public private(set) var projects: [ProjectRuntime]
    public private(set) var activeIndex: Int

    public init() {
        projects = [WorkspaceModel.makeHome()]
        activeIndex = 0
    }

    public init?(restoring restored: [ProjectRuntime], activeIndex: Int = 0) {
        guard !restored.isEmpty else { return nil }
        projects = restored
        self.activeIndex = min(max(activeIndex, 0), restored.count - 1)
        regroup()
    }

    /// The default Home project (rooted at the user's home directory).
    public static func makeHome() -> ProjectRuntime {
        ProjectRuntime(name: "Home", rootPath: NSHomeDirectory(), isHome: true)
    }

    /// Builds a restored workspace, guaranteeing a Home project exists. When the
    /// persisted list has none (existing users saved before Home), a fresh Home
    /// is prepended and `activeIndex` is remapped past it; their old home-rooted
    /// project stays as an ordinary, now-removable project. Never returns nil for
    /// a non-empty input.
    public static func restored(from persisted: [ProjectRuntime], activeIndex: Int = 0) -> WorkspaceModel? {
        var list = persisted
        var active = activeIndex
        if !list.contains(where: \.isHome) {
            list.insert(makeHome(), at: 0)
            active += 1
        }
        return WorkspaceModel(restoring: list, activeIndex: active)
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

    /// Adds a clone project (an isolated copy of `cloneSource`'s directory).
    /// Background by default — an orchestrating agent spins up N clones without
    /// stealing focus; `makeActive` switches to it.
    @discardableResult
    public func addCloneProject(name: String, rootPath: String, cloneSource: String,
                                makeActive: Bool = false) -> ProjectRuntime {
        let p = ProjectRuntime(name: name, rootPath: rootPath, cloneSource: cloneSource)
        projects.append(p)
        if makeActive { activeIndex = projects.count - 1 }
        regroup()   // slots the clone in right after its source
        return p
    }

    /// The clones of `source`, in sidebar order.
    public func clones(of source: ProjectRuntime) -> [ProjectRuntime] {
        projects.filter { $0.cloneSource == source.rootPath }
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
        // Home is never removable; it guarantees the workspace is never empty,
        // so any other project — even the last non-home one — can be removed.
        guard projects.indices.contains(index), !projects[index].isHome else { return }
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

    /// Every surface ID in the workspace — INCLUDING hibernated projects — i.e.
    /// every pane a preserved zmx session could still belong to.
    ///
    /// Ownership, not attachment. The app layer's live-surface set excludes
    /// hibernated projects because their panes are torn down, which is the right
    /// question for "what should be on screen" and the wrong one for "what may I
    /// kill": hibernating frees a project's sessions on a best-effort basis (it
    /// can't when zmx has gone missing, and a crash can cut it short), so a
    /// hibernated project's surface may still have a session behind it. Diffing
    /// against the hibernation-filtered set makes those look orphaned and kills
    /// them on the next launch — unattended, since auto-hibernation needs no user
    /// action. Reaping stays reserved for sessions no project claims at all.
    public var sessionOwnerSurfaceIDs: [UUID] {
        projects.flatMap { project in
            project.tabList.trees.flatMap { tree in
                tree.layout.surfaces.map(\.id)
            }
        }
    }

    /// Renames a project in place. Order is manual, so renaming never moves the
    /// project (unlike the old alphabetical sort).
    public func rename(projectAt index: Int, to newName: String) {
        guard projects.indices.contains(index) else { return }
        projects[index].name = newName
    }

    /// Enforces the ordering invariants: pinned projects come before unpinned
    /// ones, and each clone sits immediately after its source project (so the
    /// sidebar renders it attached). Within each group the existing relative
    /// order is preserved (`filter` is stable). Orphaned clones (source removed)
    /// stay where the base grouping puts them, as ordinary rows. The active
    /// project is preserved by identity.
    private func regroup() {
        guard !projects.isEmpty else { return }
        let activeID = projects[activeIndex].id
        let base = projects.filter(\.isHome)
            + projects.filter { !$0.isHome && $0.isPinned }
            + projects.filter { !$0.isHome && !$0.isPinned }
        let sourcePaths = Set(base.filter { $0.cloneSource == nil }.map(\.rootPath))
        let attached = base.filter { p in p.cloneSource.map(sourcePaths.contains) == true }
        var result: [ProjectRuntime] = []
        for p in base where !attached.contains(where: { $0.id == p.id }) {
            result.append(p)
            if p.cloneSource == nil {
                result += attached.filter { $0.cloneSource == p.rootPath }
            }
        }
        projects = result
        activeIndex = projects.firstIndex { $0.id == activeID } ?? 0
    }
}
