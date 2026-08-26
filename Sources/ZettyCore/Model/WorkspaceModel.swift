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
    /// The Space this project belongs to, or nil. Mutable — reassignment is the
    /// whole point — unlike `isHome`/`isScratch`/`cloneSource`, which are fixed
    /// at creation.
    public var spaceID: UUID?
    public let tabList: TabList

    public init(id: UUID = UUID(), name: String, rootPath: String,
                isPinned: Bool = false, isHibernated: Bool = false,
                isScratch: Bool = false, isHome: Bool = false, cloneSource: String? = nil,
                spaceID: UUID? = nil,
                tabList: TabList? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isPinned = isPinned
        self.isHibernated = isHibernated
        self.isScratch = isScratch
        self.isHome = isHome
        self.cloneSource = cloneSource
        self.spaceID = spaceID
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
    public private(set) var spaces: [Space] = []

    /// Seeds a fresh workspace with just the Home project, rooted at
    /// `homeRoot` (the resolved `zetty-home-path`, or the account's home
    /// directory when unset).
    public init(homeRoot: String = NSHomeDirectory()) {
        projects = [WorkspaceModel.makeHome(rootPath: homeRoot)]
        activeIndex = 0
    }

    public init?(restoring restored: [ProjectRuntime], spaces: [Space] = [], activeIndex: Int = 0) {
        guard !restored.isEmpty else { return nil }
        projects = restored
        self.spaces = spaces
        self.activeIndex = min(max(activeIndex, 0), restored.count - 1)
        regroup()
    }

    /// The Home project, rooted at `rootPath` (the user's home directory unless
    /// `zetty-home-path` moves it).
    public static func makeHome(rootPath: String = NSHomeDirectory()) -> ProjectRuntime {
        ProjectRuntime(name: "Home", rootPath: rootPath, isHome: true)
    }

    /// Builds a restored workspace, guaranteeing a Home project exists. When the
    /// persisted list has none (existing users saved before Home), a fresh Home
    /// is prepended and `activeIndex` is remapped past it; their old home-rooted
    /// project stays as an ordinary, now-removable project. Never returns nil for
    /// a non-empty input.
    ///
    /// A restored Home is re-rooted at `homeRoot`, so the config — not the
    /// `rootPath` saved in `workspace.json` — decides where Home lives. That's
    /// what makes a changed `zetty-home-path` take effect on the next launch,
    /// and what lets dropping the key move Home back to the real home directory.
    ///
    /// Spaces restore alongside projects, and `regroup()` clears any
    /// membership whose Space is gone.
    public static func restored(from persisted: [ProjectRuntime], spaces: [Space] = [],
                                activeIndex: Int = 0,
                                homeRoot: String = NSHomeDirectory()) -> WorkspaceModel? {
        var list = persisted
        var active = activeIndex
        if !list.contains(where: \.isHome) {
            list.insert(makeHome(rootPath: homeRoot), at: 0)
            active += 1
        }
        let model = WorkspaceModel(restoring: list, spaces: spaces, activeIndex: active)
        model?.setHomeRoot(homeRoot)
        return model
    }

    /// Re-roots the Home project at `path`: new tabs and panes open there.
    /// Existing panes keep their working directories — a live shell owns its cwd,
    /// and a preserved zmx session captured it when it was created.
    ///
    /// Called on launch and whenever ⇧⌘, reloads a changed `zetty-home-path`.
    /// Returns true when the root actually moved, so a caller can refresh chrome
    /// and persist only on a real change.
    @discardableResult
    public func setHomeRoot(_ path: String) -> Bool {
        guard let home = projects.first(where: \.isHome), home.rootPath != path else { return false }
        home.rootPath = path
        home.tabList.setDefaultWorkingDir(path)
        return true
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
        // Pinning means "lives in the Pinned section", and a Space member lives
        // in its Space — one project, one section. The sidebar hides the star
        // for members, so this guard is the model-side half of that rule.
        guard projects.indices.contains(index), projects[index].spaceID == nil else { return }
        projects[index].isPinned.toggle()
        regroup()   // pinning drops the project at the bottom of its new group
    }

    /// Moves a project from one position to another within the same section.
    /// The active project is preserved by identity. Callers must keep the move
    /// within one pin-group (Pinned ↔ Pinned, unpinned ↔ unpinned) AND one Space;
    /// a cross-group or cross-Space move is rejected so the pinned-first
    /// invariant can't be broken and `assign`'s refusals can't be bypassed.
    /// Reassignment to a different Space goes through `assign(projectAt:to:)`.
    public func moveProject(from: Int, to: Int) {
        // Both endpoints must share pin state AND Space: a reorder may never
        // move a project across a Space boundary, which would bypass `assign`'s
        // refusals. Reassignment goes through `assign(projectAt:to:)`.
        guard projects.indices.contains(from), projects.indices.contains(to),
              from != to,
              projects[from].isPinned == projects[to].isPinned,
              projects[from].spaceID == projects[to].spaceID else { return }
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

    // MARK: - Spaces

    /// Creates a Space and appends it to the end of the sidebar order. Returns
    /// nil for a blank name or one that collides case-insensitively with an
    /// existing Space — names are the CLI's handle, so they must be unique.
    @discardableResult
    public func createSpace(name: String, colorID: String? = nil, glyph: String? = nil) -> Space? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, space(named: trimmed) == nil else { return nil }
        let created = Space(name: trimmed, colorID: colorID, glyph: glyph)
        spaces.append(created)
        return created
    }

    /// Renames a Space. False (and no change) for a blank name or a
    /// case-insensitive collision with a DIFFERENT Space.
    @discardableResult
    public func renameSpace(id: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = spaces.firstIndex(where: { $0.id == id }),
              !spaces.contains(where: {
                  $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
              })
        else { return false }
        spaces[index].name = trimmed
        return true
    }

    /// Appearance only — never reorders or reassigns.
    public func updateSpace(id: UUID, colorID: String?, glyph: String?) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].colorID = colorID
        spaces[index].glyph = glyph
    }

    public func setSpaceCollapsed(id: UUID, _ collapsed: Bool) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].isCollapsed = collapsed
    }

    /// Deletes a Space. Its members are KEPT — their `spaceID` is cleared and
    /// they fall back to Pinned/Projects.
    public func removeSpace(id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        spaces.removeAll { $0.id == id }
        for project in projects where project.spaceID == id { project.spaceID = nil }
        regroup()
    }

    /// Reorders the Spaces themselves; members follow via `regroup()`.
    public func moveSpace(from: Int, to: Int) {
        guard spaces.indices.contains(from), spaces.indices.contains(to), from != to else { return }
        let moved = spaces.remove(at: from)
        spaces.insert(moved, at: to)
        regroup()
    }

    /// Assigns a project to a Space (nil = ungroup). Refuses Home, Scratch, and
    /// clones — Home owns the top row, Scratch is ephemeral, and a clone renders
    /// glued beneath its source, so its Space is its source's by construction.
    /// Also refuses an unknown `spaceID` so a stale id can't strand a project.
    @discardableResult
    public func assign(projectAt index: Int, to spaceID: UUID?) -> Bool {
        guard projects.indices.contains(index) else { return false }
        let project = projects[index]
        guard !project.isHome, !project.isScratch, project.cloneSource == nil else { return false }
        if let spaceID, !spaces.contains(where: { $0.id == spaceID }) { return false }
        project.spaceID = spaceID
        // Joining a Space leaves the Pinned section, so the pin goes with it.
        if spaceID != nil { project.isPinned = false }
        // Re-append so the project lands LAST among its destination's members.
        // `regroup()` filters stably, so member order is array order — and since
        // the Spaces block sits after Projects, leaving the project in place
        // would order members by where they happened to sit in the array, which
        // reverses assign order. Members can't be drag-sorted, so "the one you
        // just filed appears last" is the only order a user can predict.
        projects.remove(at: index)
        projects.append(project)
        regroup()
        return true
    }

    /// Case-insensitive lookup — the control CLI addresses Spaces by name.
    public func space(named name: String) -> Space? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return spaces.first { $0.name.localizedCaseInsensitiveCompare(needle) == .orderedSame }
    }

    /// Re-applies the ordering invariants after a caller mutates a project
    /// field `WorkspaceModel` does not own the write to — today that means
    /// `isHibernated`, which the app layer sets directly on the runtime.
    ///
    /// Needed because a Space orders its members awake-before-dormant, so
    /// hibernating a member has to re-sort its Space; without this the new
    /// order would not appear until some unrelated change happened to trigger
    /// `regroup()`.
    public func reapplyOrdering() {
        regroup()
    }

    /// A Space's members in sidebar order, hibernated ones included.
    public func projects(inSpace id: UUID) -> [ProjectRuntime] {
        projects.filter { $0.spaceID == id }
    }

    /// The Space a project RENDERS under, which for a clone is its source's:
    /// a clone's own `spaceID` is always nil (`assign` refuses clones) and it
    /// rides into its source's Space through `regroup()`'s gluing pass. Callers
    /// that report or render a project's Space must use this rather than
    /// `spaceID`, or a clone reads as a gap in the middle of its Space.
    /// An orphaned clone (source removed) correctly resolves to nil.
    public func effectiveSpaceID(of project: ProjectRuntime) -> UUID? {
        if let spaceID = project.spaceID { return spaceID }
        guard let sourcePath = project.cloneSource else { return nil }
        return projects.first { $0.cloneSource == nil && $0.rootPath == sourcePath }?.spaceID
    }

    /// Enforces the ordering invariants, mirroring the sidebar's sections:
    /// Home · spaceless pinned · spaceless unpinned · each Space in `spaces`
    /// order · Scratch terminals last. Inside a Space, awake members come
    /// before dormant ones, so hibernating a member sinks it to the bottom of
    /// its own Space instead of scattering it among the live ones. Members are
    /// never pinned — joining a Space clears the pin, and this normalises any
    /// that slipped through.
    ///
    /// Within all of that, each clone sits immediately after its source project
    /// (so the sidebar renders it attached). Gluing wins over the awake/dormant
    /// split, so a hibernated clone of an awake source stays beside its source
    /// rather than sinking — the attachment is the load-bearing invariant.
    ///
    /// Within each group the existing relative order is preserved (`filter` is
    /// stable, never sorted). Orphaned clones (source removed) stay where the
    /// base grouping puts them, as ordinary rows. The active project is
    /// preserved by identity.
    private func regroup() {
        guard !projects.isEmpty else { return }
        let activeID = projects[activeIndex].id
        // Drop memberships pointing at a Space that no longer exists, so a
        // hand-edited or partially-restored workspace can't hide a project.
        let known = Set(spaces.map(\.id))
        for project in projects where project.spaceID.map({ !known.contains($0) }) == true {
            project.spaceID = nil
        }
        // A Space member is never pinned — self-healing, so a workspace.json
        // written before this rule (or hand-edited) converges on load instead
        // of leaving a starred row inside a Space.
        for project in projects where project.spaceID != nil && project.isPinned {
            project.isPinned = false
        }
        let rest = projects.filter { !$0.isHome }
        // Scratch terminals are held back and appended after the Spaces block so
        // model order matches the sidebar's (Home · Pinned · Projects · Spaces ·
        // Scratch · Hibernating) — `zetty status` renders model order, so the two
        // surfaces would otherwise disagree about where a scratch terminal sits.
        let spaceless = rest.filter { $0.spaceID == nil && !$0.isScratch }
        var base = projects.filter(\.isHome)
            + spaceless.filter(\.isPinned)
            + spaceless.filter { !$0.isPinned }
        for space in spaces {
            // Members are never pinned (normalised above), so the only split
            // inside a Space is awake before dormant. Order within each half is
            // assign order — `assign` re-appends, so re-picking the same Space
            // from the menu moves a member to the bottom.
            let members = rest.filter { $0.spaceID == space.id }
            base += members.filter { !$0.isHibernated }
            base += members.filter(\.isHibernated)
        }
        base += rest.filter { $0.spaceID == nil && $0.isScratch }
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
