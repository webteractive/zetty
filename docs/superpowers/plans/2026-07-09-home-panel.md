# Home Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-class, non-removable, hibernatable **Home** project — seeded by default, in its own top sidebar section, with full project settings keyed by a sentinel.

**Architecture:** Home is a `ProjectRuntime` with a new `isHome` flag (sibling to `isScratch`). Pure `ZettyCore` handles seeding, restore-injection, ordering, removal-rejection, persistence, and settings-key routing; the app layer adds the sidebar section, context menu, a relaxed hibernation guard, and CLI rejection. No new terminal concept — Home reuses the entire project/tab/settings stack.

**Tech Stack:** Swift, AppKit, Swift Testing (`import Testing`), Tuist-generated Xcode project, SwiftPM for pure `ZettyCore`.

## Global Constraints

- `ZettyCore` stays pure — **no AppKit import** in `Sources/ZettyCore/**`.
- No hardcoded colors; read `ZTheme` (no new tokens expected here).
- No debug `NSLog`/`print`.
- **Document user-facing changes in `README.md`** in the same change.
- **Keep `CLAUDE.md` and `AGENTS.md` byte-identical.**
- Never commit/push without being asked; no `Co-Authored-By` / session link.
- **Don't create a git branch unless implied** (project rule) — work on `main`.
- Wire/persistence stays backward-compatible: new fields decode with `decodeIfPresent(...) ?? false`.
- Exactly one Home always exists; Home can be hibernated but never removed.
- Pure tests: `mise exec -- swift test` (single: `--filter <name>`). App: `mise exec -- tuist test`.
- After adding/removing a source file, regenerate: `mise exec -- tuist generate --no-open`.

---

### Task 1: `isHome` model flag — seed, restore-inject, ordering, removal

**Files:**
- Modify: `Sources/ZettyCore/Model/WorkspaceModel.swift`
- Test: `Tests/ZettyCoreTests/WorkspaceModelTests.swift`

**Interfaces:**
- Produces:
  - `ProjectRuntime.isHome: Bool` (init param, default `false`; stored `let`).
  - `WorkspaceModel.makeHome() -> ProjectRuntime` (static; name `"Home"`, rootPath `NSHomeDirectory()`, `isHome: true`).
  - `WorkspaceModel.init()` seeds a single Home.
  - `WorkspaceModel.init?(restoring:activeIndex:)` injects Home at index 0 when none present (remapping `activeIndex`).
  - `WorkspaceModel.removeProject(at:)` rejects `isHome` and allows removing the last non-home project.
  - `regroup()` orders Home first, then pinned, then unpinned.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ZettyCoreTests/WorkspaceModelTests.swift`:

```swift
@Test func defaultInitSeedsHome() {
    let ws = WorkspaceModel()
    #expect(ws.projects.count == 1)
    #expect(ws.projects[0].isHome)
    #expect(ws.projects[0].name == "Home")
}

@Test func restoreInjectsHomeWhenAbsent() {
    // Existing users: restored projects have no isHome → Home is prepended.
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "Homedir", rootPath: "/Users/x"),
        ProjectRuntime(name: "api", rootPath: "/Users/x/api"),
    ], activeIndex: 1)!
    #expect(ws.projects.first!.isHome)
    #expect(ws.projects.count == 3)
    // activeIndex remapped past the inserted Home → still points at "api".
    #expect(ws.activeProject.name == "api")
}

@Test func restoreKeepsExistingHome() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "Home", rootPath: "/Users/x", isHome: true),
        ProjectRuntime(name: "api", rootPath: "/Users/x/api"),
    ], activeIndex: 0)!
    #expect(ws.projects.filter(\.isHome).count == 1)   // no duplicate injected
    #expect(ws.projects.count == 2)
}

@Test func removeProjectRejectsHome() {
    let ws = WorkspaceModel()                 // just Home
    _ = ws.addProject(name: "api", rootPath: "/a")
    let homeIndex = ws.projects.firstIndex(where: \.isHome)!
    ws.removeProject(at: homeIndex)
    #expect(ws.projects.contains { $0.isHome })   // still there
}

@Test func removeProjectAllowsLastNonHome() {
    let ws = WorkspaceModel()                 // Home
    _ = ws.addProject(name: "api", rootPath: "/a")
    let apiIndex = ws.projects.firstIndex { $0.name == "api" }!
    ws.removeProject(at: apiIndex)            // removing the only non-home project
    #expect(ws.projects.count == 1)
    #expect(ws.projects[0].isHome)
}

@Test func homeSortsFirst() {
    let ws = WorkspaceModel()
    let pinned = ws.addProject(name: "pinned", rootPath: "/p")
    ws.togglePin(at: ws.projects.firstIndex { $0.id == pinned.id }!)
    #expect(ws.projects[0].isHome)            // Home ahead of pinned
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- swift test --filter defaultInitSeedsHome`
Expected: FAIL — `ProjectRuntime` has no `isHome`.

- [ ] **Step 3: Implement**

In `Sources/ZettyCore/Model/WorkspaceModel.swift`:

Add the flag to `ProjectRuntime` (after `isScratch`):

```swift
    public let isScratch: Bool
    /// The permanent, non-removable Home project: seeded by default, lives in
    /// its own top sidebar section, can be hibernated but never removed.
    public let isHome: Bool
    public let tabList: TabList

    public init(id: UUID = UUID(), name: String, rootPath: String,
                isPinned: Bool = false, isHibernated: Bool = false,
                isScratch: Bool = false, isHome: Bool = false, tabList: TabList? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isPinned = isPinned
        self.isHibernated = isHibernated
        self.isScratch = isScratch
        self.isHome = isHome
        self.tabList = tabList ?? TabList(defaultWorkingDir: rootPath)
    }
```

Replace the two initializers of `WorkspaceModel` and add `makeHome()`:

```swift
    public init() {
        projects = [WorkspaceModel.makeHome()]
        activeIndex = 0
    }

    public init?(restoring restored: [ProjectRuntime], activeIndex: Int = 0) {
        guard !restored.isEmpty else { return nil }
        var list = restored
        var active = activeIndex
        // Existing users (saved before Home) get a fresh Home prepended; their
        // old home-rooted project stays as an ordinary, now-removable project.
        if !list.contains(where: \.isHome) {
            list.insert(WorkspaceModel.makeHome(), at: 0)
            active += 1
        }
        projects = list
        self.activeIndex = min(max(active, 0), list.count - 1)
        regroup()
    }

    /// The default Home project (rooted at the user's home directory).
    public static func makeHome() -> ProjectRuntime {
        ProjectRuntime(name: "Home", rootPath: NSHomeDirectory(), isHome: true)
    }
```

Replace `removeProject(at:)`:

```swift
    public func removeProject(at index: Int) {
        guard projects.indices.contains(index), !projects[index].isHome else { return }
        // Home guarantees the workspace is never empty, so no count>1 guard.
        projects.remove(at: index)
        if activeIndex >= projects.count {
            activeIndex = projects.count - 1
        } else if index < activeIndex {
            activeIndex -= 1
        }
    }
```

Replace `regroup()` body's ordering line (Home first):

```swift
    private func regroup() {
        guard !projects.isEmpty else { return }
        let activeID = projects[activeIndex].id
        projects = projects.filter(\.isHome)
            + projects.filter { !$0.isHome && $0.isPinned }
            + projects.filter { !$0.isHome && !$0.isPinned }
        activeIndex = projects.firstIndex { $0.id == activeID } ?? 0
    }
```

- [ ] **Step 4: Run to verify passing**

Run: `mise exec -- swift test --filter WorkspaceModel` then `mise exec -- swift test`
Expected: PASS. (Existing `WorkspaceModelTests` that call `WorkspaceModel()` may now see a Home-named project instead of a home-basename project — if any assert on the seeded project's `name`, update that assertion to expect `"Home"`.)

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Model/WorkspaceModel.swift Tests/ZettyCoreTests/WorkspaceModelTests.swift
git commit -m "feat(core): isHome project — seed, restore-inject, home-first order, non-removable"
```

---

### Task 2: Persist `isHome` in `workspace.json`

**Files:**
- Modify: `Sources/ZettyCore/Model/Project.swift` (persisted `Project` struct)
- Modify: `Sources/ZettyCore/Persistence/SessionSnapshot.swift`
- Test: `Tests/ZettyCoreTests/PersistenceTests.swift` (or `SessionSnapshotTests.swift`)

**Interfaces:**
- Consumes: `ProjectRuntime.isHome` (Task 1).
- Produces: persisted `Project.isHome: Bool` (default false, tolerant decode); `SessionSnapshot.workspace(from:)` writes it; `projectRuntimes(from:)` restores it.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ZettyCoreTests/SessionSnapshotTests.swift`:

```swift
@Test func isHomeRoundTripsThroughSnapshot() {
    let ws = WorkspaceModel()                       // seeds Home
    _ = ws.addProject(name: "api", rootPath: "/a")
    let saved = SessionSnapshot.workspace(from: ws)
    #expect(saved.projects.contains { $0.isHome })

    let restored = SessionSnapshot.projectRuntimes(from: saved)
    #expect(restored.filter(\.isHome).count == 1)
    #expect(restored.first(where: \.isHome)?.name == "Home")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- swift test --filter isHomeRoundTripsThroughSnapshot`
Expected: FAIL — `Project` has no `isHome` (compile error) or the flag is dropped.

- [ ] **Step 3: Implement**

In `Sources/ZettyCore/Model/Project.swift`, add the field to the `Project` struct:

```swift
    public var isPinned: Bool
    public var sortOrder: Int
    public var preserveSessions: Bool
    public var isHibernated: Bool
    public var isHome: Bool
    public var sessions: [Session]

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        isPinned: Bool = false,
        sortOrder: Int = 0,
        preserveSessions: Bool = false,
        isHibernated: Bool = false,
        isHome: Bool = false,
        sessions: [Session] = []
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isPinned = isPinned
        self.sortOrder = sortOrder
        self.preserveSessions = preserveSessions
        self.isHibernated = isHibernated
        self.isHome = isHome
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, isPinned, sortOrder, preserveSessions, isHibernated, isHome, sessions
    }
```

Add to the tolerant `init(from:)` (after the `isHibernated` line):

```swift
        isHibernated = try c.decodeIfPresent(Bool.self, forKey: .isHibernated) ?? false
        isHome = try c.decodeIfPresent(Bool.self, forKey: .isHome) ?? false
```

In `Sources/ZettyCore/Persistence/SessionSnapshot.swift`, `workspace(from:)` — pass `isHome` into the `Project(...)`:

```swift
            return Project(
                name: runtime.name,
                rootPath: runtime.rootPath,
                isPinned: runtime.isPinned,
                sortOrder: savedIndex,
                isHibernated: runtime.isHibernated,
                isHome: runtime.isHome,
                sessions: [Session(title: "main", tabs: tabs, activeTabIndex: runtime.tabList.activeIndex)]
            )
```

And `projectRuntimes(from:)` — pass `isHome` into the `ProjectRuntime(...)`:

```swift
            return ProjectRuntime(
                name: project.name,
                rootPath: project.rootPath,
                isPinned: project.isPinned,
                isHibernated: project.isHibernated,
                isHome: project.isHome,
                tabList: tabList
            )
```

- [ ] **Step 4: Run to verify passing**

Run: `mise exec -- swift test --filter isHomeRoundTrips` then `mise exec -- swift test`
Expected: PASS, whole suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Model/Project.swift Sources/ZettyCore/Persistence/SessionSnapshot.swift Tests/ZettyCoreTests/SessionSnapshotTests.swift
git commit -m "feat(core): persist isHome in workspace.json"
```

---

### Task 3: Settings sentinel key for Home

**Files:**
- Modify: `Sources/ZettyCore/Settings/ProjectSettingsStore.swift`
- Modify: `Sources/ZettyCore/Model/WorkspaceModel.swift` (add `ProjectRuntime.settingsKey`)
- Test: `Tests/ZettyCoreTests/ProjectSettingsTests.swift`

**Interfaces:**
- Consumes: `ProjectRuntime.isHome` (Task 1); `ProjectSettingsStore.canonicalKey`.
- Produces:
  - `ProjectSettingsStore.homeKey: String` (`"@home"`).
  - `ProjectSettingsStore.canonicalKey(_:)` returns `homeKey` unchanged when passed `homeKey`.
  - `ProjectRuntime.settingsKey: String` → `isHome ? ProjectSettingsStore.homeKey : rootPath`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ZettyCoreTests/ProjectSettingsTests.swift`:

```swift
@Test func homeSettingsKeyIsSentinelNotPath() {
    let home = ProjectRuntime(name: "Home", rootPath: NSHomeDirectory(), isHome: true)
    #expect(home.settingsKey == ProjectSettingsStore.homeKey)

    // A normal project at ~ keys by its path, so it never collides with Home.
    let tildeProject = ProjectRuntime(name: "dotfiles", rootPath: NSHomeDirectory())
    #expect(tildeProject.settingsKey != ProjectSettingsStore.homeKey)

    var file = ProjectSettingsFile()
    var s = ProjectSettings(); s.name = "My Home"
    file.set(s, for: home.settingsKey)
    #expect(file.settings(for: home.settingsKey)?.name == "My Home")
    #expect(file.settings(for: tildeProject.settingsKey) == nil)   // no collision
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- swift test --filter homeSettingsKeyIsSentinelNotPath`
Expected: FAIL — no `ProjectSettingsStore.homeKey` / no `settingsKey`.

- [ ] **Step 3: Implement**

In `Sources/ZettyCore/Settings/ProjectSettingsStore.swift`, add the sentinel and short-circuit:

```swift
    /// Reserved settings key for the Home project — not a real path, so it never
    /// collides with a user-added `~` project.
    public static let homeKey = "@home"

    public static func canonicalKey(_ rootPath: String) -> String {
        if rootPath == homeKey { return homeKey }
        var path = (rootPath as NSString).expandingTildeInPath
        path = (path as NSString).standardizingPath
        path = URL(fileURLWithPath: path).standardizedFileURL
            .resolvingSymlinksInPath().path
        return path
    }
```

In `Sources/ZettyCore/Model/WorkspaceModel.swift`, add a computed property to `ProjectRuntime` (after the stored properties / init):

```swift
    /// The key under which this project's settings are stored. Home uses a
    /// reserved sentinel so it never shares an entry with a user `~` project.
    public var settingsKey: String {
        isHome ? ProjectSettingsStore.homeKey : rootPath
    }
```

- [ ] **Step 4: Run to verify passing**

Run: `mise exec -- swift test --filter ProjectSettings` then `mise exec -- swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Settings/ProjectSettingsStore.swift Sources/ZettyCore/Model/WorkspaceModel.swift Tests/ZettyCoreTests/ProjectSettingsTests.swift
git commit -m "feat(core): route Home project settings through a reserved sentinel key"
```

---

### Task 4: App layer — sidebar Home section, context menu, hibernation, settings key, remove rejection

**Files:**
- Modify: `App/Sources/App/SidebarView.swift` (section enum, classification, row grouping, context menu)
- Modify: `App/Sources/App/TerminalViewController.swift` (`hibernateProject` guard; `removeProjectNamed` rejection)
- Modify: `App/Sources/App/AppDelegate.swift` (settings calls use `settingsKey`; Home fallback name)
- No unit tests (app layer needs live libghostty + window → build + manual, see Step 6).

**Interfaces:**
- Consumes: Task 1–3 (`isHome`, `settingsKey`, seeding).
- Produces: `SidebarSection.home`; Home row without a Remove item; relaxed hibernation; settings resolved via `settingsKey`.

- [ ] **Step 1: Sidebar section + classification + ordering**

In `App/Sources/App/SidebarView.swift`, add `.home` to the `SidebarSection` enum and its title (near lines 37–47):

```swift
private enum SidebarSection: Hashable {
    case home
    case pinned
    case projects
    case scratch
    // ...existing cases if any (e.g. hibernating handled separately)...

    var title: String {
        switch self {
        case .home:       return "Home"
        case .pinned:     return "Pinned"
        case .projects:   return "Projects"
        case .scratch:    return "Scratch"
        }
    }
}
```

Update the classifier (near lines 799–800):

```swift
        if p.isHome { return .home }
        if p.isScratch { return .scratch }
        return p.isPinned ? .pinned : .projects
```

Update the section grouping so Home renders first (near lines 472–480). After computing `awake`/`scratch`/`regular`, split Home out and place it first:

```swift
        let home = awake.filter { $0.element.isHome }
        let scratch = awake.filter { $0.element.isScratch }
        let regular = awake.filter { !$0.element.isScratch && !$0.element.isHome }
        let pinned = regular.filter { $0.element.isPinned }
        let unpinned = regular.filter { !$0.element.isPinned }
        // Section render order: Home · Pinned · Projects · Scratch · Hibernating.
```

Then include `home` first wherever `pinned`/`unpinned`/`scratch` are assembled into the rendered section list (mirror the existing pattern for a `.home` group with `home`). Follow the exact assembly idiom already in this method — add `.home` as the first section when `home` is non-empty (it always is).

- [ ] **Step 2: Context menu — no Remove for Home**

In `SidebarView.swift` (near lines 604–624), the menu builds per-project. Home must show Project Settings + Hibernate/Wake but NOT Remove. Adjust the guards:

```swift
        let isScratch = projects[p].isScratch
        let isHome = projects[p].isHome
        // Per-project settings for everything except scratch.
        if !isScratch {
            // ...existing Rename… / Project Settings… / Hibernate items...
        }
        // Remove/Close: scratch → "Close Terminal"; Home → omitted entirely.
        if !isHome {
            let remove = NSMenuItem(title: isScratch ? "Close Terminal" : "Remove Project\u{2026}",
                                    /* ...existing action/target... */)
            // ...existing append...
        }
```

(Keep the exact action selectors/targets already in place; only the `if !isHome` guard around the Remove item and the `isHome` binding are new.)

- [ ] **Step 3: Relax the hibernation guard**

In `App/Sources/App/TerminalViewController.swift`, `hibernateProject(_:confirmIfBusy:)` (near lines 2224–2241). Drop the `count > 1` requirement and make the switch-away optional:

```swift
    func hibernateProject(_ project: ProjectRuntime, confirmIfBusy: Bool = true) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == project.id }),
              !project.isHibernated else { return }
        let surfaceIDs = project.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }
        if confirmIfBusy, !confirmClosingBusyPanes(surfaceIDs, what: "project “\(project.name)”") { return }

        if index == workspace.activeIndex {
            // Switch to another awake project if one exists; otherwise stay put and
            // let the dormant placeholder render (full-dormancy allowed for Home).
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
        rebuildSurfaceNodeView()               // renders placeholder when active is hibernated
        // ...keep the rest of the existing method body unchanged...
    }
```

(Only the `guard` — remove `workspace.projects.count > 1` — and the `if let target` softening change; leave everything after `project.isHibernated = true` as-is.)

- [ ] **Step 4: Settings key + Home fallback name + remove rejection**

In `App/Sources/App/AppDelegate.swift`, replace `project.rootPath` with `project.settingsKey` in the per-project **settings** call sites only (NOT `ProjectFileIO.load(projectRoot:)`, which is the repo layout file). These are near lines 157, 172, 175, 682, 695, 697:

```swift
            let settings = self.projectSettings.settings(for: project.settingsKey)
```
```swift
            self?.projectSettings.settings(for: project.settingsKey)?.autoHibernate == false
```
```swift
            BroadcastScope(code: self?.projectSettings.settings(for: project.settingsKey)?.broadcastScope)
```

In `resolvedSettings(for:)` (near line 680), use `settingsKey` and a Home-aware fallback name:

```swift
    func resolvedSettings(for project: ProjectRuntime) -> ResolvedProjectSettings {
        ProjectSettingsResolver.resolve(
            projectSettings.settings(for: project.settingsKey),
            fallbackName: project.isHome ? "Home" : (project.rootPath as NSString).lastPathComponent,
            // ...rest of the existing arguments unchanged...
        )
    }
```

In `updateProjectSettings(_:for:)` (near lines 695–697), use `settingsKey`:

```swift
        var settings = projectSettings.settings(for: project.settingsKey) ?? ProjectSettings()
        // ...existing mutation...
        projectSettings.set(settings, for: project.settingsKey)
```

In `App/Sources/App/TerminalViewController.swift`, `removeProjectNamed(_:)` (near line 1428) — reject Home and drop the "only project" guard (Home is the floor):

```swift
    func removeProjectNamed(_ name: String) -> String? {
        let matches = workspace.projects.enumerated().filter {
            $0.element.name.lowercased() == name.lowercased()
        }
        guard let match = matches.first else {
            return "no project named \"\(name)\""
        }
        guard matches.count == 1 else {
            return "\(matches.count) projects named \"\(name)\" — remove it via the sidebar"
        }
        guard !match.element.isHome else {
            return "Home can't be removed"
        }
        performRemoveProject(at: match.offset)
        return nil
    }
```

- [ ] **Step 5: Build**

Run:
```bash
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Manual runtime verification (GUI)**

Rebuild + install to `/Applications`, relaunch, then:
1. **Home present & first:** the sidebar shows a **Home** section at the top with one row; it has no "Remove Project" in its right-click menu, but does have Project Settings… and Hibernate.
2. **Non-removable via CLI:** `zetty remove-project Home` → prints `Home can't be removed`, exit 1.
3. **Hibernate/wake Home:** right-click Home → Hibernate; if it's the only awake project the main area shows the dormant placeholder + Wake; Wake restores it.
4. **Settings + no collision:** open Home → Project Settings…, set a curated color; add `~` as a normal project (`zetty add-project ~`) and confirm its settings are independent of Home's.
5. **Remove last normal project:** remove every non-home project; Home remains and the app is still usable.
6. **Restart persistence:** quit + relaunch (preserve-sessions) → Home returns in its section with its tabs.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/App/SidebarView.swift App/Sources/App/TerminalViewController.swift App/Sources/App/AppDelegate.swift
git commit -m "feat(app): Home sidebar section, non-removable, hibernatable, sentinel settings"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md` and `AGENTS.md` (byte-identical)

**Interfaces:** none (docs only).

- [ ] **Step 1: README**

In the Features list, add a bullet describing **Home** — a permanent, always-present terminal in its own sidebar section that can't be removed but can be hibernated/woken and carries its own project settings. In the Control CLI notes, mention `zetty remove-project Home` is rejected and Home is targetable by name (`--project Home`).

- [ ] **Step 2: CLAUDE.md + AGENTS.md (identical)**

Add a short paragraph (near the project-settings / sidebar description) documenting the Home project: seeded by default, non-removable, hibernatable, own sidebar section, settings keyed by the `@home` sentinel, `remove-project Home` rejected. Then:

```bash
diff CLAUDE.md AGENTS.md && echo IDENTICAL
```
Expected: `IDENTICAL`.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md AGENTS.md docs/plans/2026-07-09-home-panel-design.md docs/superpowers/plans/2026-07-09-home-panel.md
git commit -m "docs: document the Home panel + design/plan"
```

---

## Self-Review

**Spec coverage** (design → task):
- New `isHome` construct, seeded by default → Task 1 ✅
- Restore-injects Home for existing users; old Homedir stays normal → Task 1 (`init?(restoring:)`) ✅
- Non-removable (model + CLI) → Task 1 (`removeProject`) + Task 4 (`removeProjectNamed`) ✅
- Drop "can't remove last project"; Home is the floor → Task 1 ✅
- Own sidebar section, first, no Remove menu → Task 4 Steps 1–2 ✅
- Hibernatable incl. full dormancy → Task 4 Step 3 (relaxed guard; existing placeholder) ✅
- Full project settings via sentinel key, no `~` collision → Task 3 + Task 4 Step 4 ✅
- Persisted in workspace.json → Task 2 ✅
- CLI: targetable by name, `remove-project Home` rejected → Task 4 Step 4 (name match already works via existing `openNewTab`/`hibernateProjectNamed`) ✅
- Scratch unchanged → untouched ✅
- Docs → Task 5 ✅

**Placeholder scan:** Task 4 Steps 1–2 intentionally reference "the existing assembly idiom / action selectors" rather than reproducing the entire `SidebarView` menu-builder verbatim — the exact surrounding code is cited by line range and must be read in-file; the *new* lines (the `.home` case, classifier line, `if !isHome` guard, `home`/`regular` split) are given in full. This is a deliberate "follow the established pattern in a large existing file" instruction, not a TODO. All model/persistence/settings steps (Tasks 1–3) show complete code.

**Type consistency:** `isHome` (Bool), `makeHome() -> ProjectRuntime`, `settingsKey: String`, `ProjectSettingsStore.homeKey`, `SidebarSection.home` used consistently across tasks. Persisted `Project.isHome` ↔ runtime `ProjectRuntime.isHome` bridged in Task 2 both directions.

**Known verification gap:** app-layer behavior (sidebar, menu, hibernation, settings sheet) isn't unit-tested (needs live libghostty + window; `ZettyCore` stays AppKit-free) — covered by the Task 4 Step 6 manual checklist, consistent with the repo and the TCC-blocked-GUI constraint.
