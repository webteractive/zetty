# quertty Phase 1 — Sidebar (Projects) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a left sidebar listing **projects** (directories). Each project owns its own tabs/splits (`TabList`); selecting a project swaps the whole tab/pane area to that project's layout. Support add-project (pick a directory), pin/unpin, switch, and persist the full set across launches.

**Architecture:** A new pure `WorkspaceModel` (in `QuerttyCore`) holds an ordered list of `ProjectRuntime`s — each = project metadata (name/rootPath/isPinned) + its own `TabList` — plus an active-project index. `TerminalViewController` owns the `WorkspaceModel` and renders the **active project's** `TabList`; the existing `paneTree`/tab/split/registry machinery is unchanged below the active `TabList`. A `SidebarView` (AppKit) lists projects and drives select/add/pin via callbacks. Persistence extends the existing `Workspace`/`WorkspaceStore` round-trip to many real projects.

**Tech Stack:** Swift 6, SPM (`QuerttyCore`) + Tuist app, AppKit, Swift Testing (`QuerttyCore`), `libghostty-spm`.

## Global Constraints

- **Layer rule:** `QuerttyCore` imports only Swift + Foundation (`WorkspaceModel`, `ProjectRuntime`, persistence mapping are pure — no AppKit). The `SidebarView` and `NSOpenPanel` live in the app target.
- **Each project owns its `TabList`.** Switching the active project swaps which `TabList` the pane area renders. Session is collapsed into tabs for now (one default `Session` per project at the persistence layer).
- **Session preservation across project switch:** the `SurfaceRegistry` prunes to the UNION of surface ids across **all projects' all tabs**, so switching projects keeps background projects' live terminals. (Known scaling caveat: many projects × tabs = many PTYs; lazy-spawn/suspend is a later concern — `log`/note it, don't silently cap.)
- **Tests:** `QuerttyCore` logic via Swift Testing (`apple/swift-testing` pkg, already wired); app via build + manual. A benign `@Test` deprecation warning is the known accepted artifact.
- **Reuse:** build on `TabList`, `PaneTree`, `Layout`, `Surface`, `Project`/`Session`/`Tab`/`Workspace`/`WorkspaceStore`, `SessionSnapshot`, `SurfaceRegistry` — all exist and are tested. Do NOT rebuild them.
- **App entry/window:** unchanged (`main.swift` bootstrap, `QuerttyWindow` menu-priority, `AppDelegate`). Add sidebar inside the window's content.
- **Commits:** frequent, one per task min; `git -c commit.gpgsign=false commit`; clean (NO leftover debug `NSLog`/`print` — a prior agent committed debug logs; do not repeat). Build the app headlessly with `mise exec -- tuist build quertty`; GUI is user-verified. Accessibility is granted, so synthesized-input smoke checks are possible but optional — remove any temp logs before committing.

---

### Task 1: `ProjectRuntime` + `WorkspaceModel` (QuerttyCore, TDD)

**Files:**
- Create: `Sources/QuerttyCore/Model/WorkspaceModel.swift`
- Create: `Tests/QuerttyCoreTests/WorkspaceModelTests.swift`

**Interfaces:**
- Consumes: `TabList` (existing).
- Produces:
  - `final class ProjectRuntime` — `let id: UUID`, `var name: String`, `var rootPath: String`, `var isPinned: Bool`, `let tabList: TabList`. Init `(id:name:rootPath:isPinned:tabList:)` with defaults (`id = UUID()`, `isPinned = false`, `tabList = TabList()`).
  - `final class WorkspaceModel` — `private(set) var projects: [ProjectRuntime]` (always non-empty), `private(set) var activeIndex: Int`; `var activeProject: ProjectRuntime`; `var activeTabList: TabList`; `init()` seeds one default project (name from `rootPath`'s last component, `rootPath = NSHomeDirectory()`); `init?(restoring: [ProjectRuntime], activeIndex: Int)` (nil if empty, clamps); `addProject(name:rootPath:) -> ProjectRuntime` (appends, makes active); `removeProject(at:)` (no-op if it would empty the list; clamps activeIndex like `TabList.closeTab`); `select(index:)`; `togglePin(at:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/QuerttyCoreTests/WorkspaceModelTests.swift
import Testing
@testable import QuerttyCore

@Test func seedsOneActiveProject() {
    let ws = WorkspaceModel()
    #expect(ws.projects.count == 1)
    #expect(ws.activeIndex == 0)
}

@Test func addProjectAppendsAndActivates() {
    let ws = WorkspaceModel()
    let p = ws.addProject(name: "web", rootPath: "/tmp/web")
    #expect(ws.projects.count == 2)
    #expect(ws.activeIndex == 1)
    #expect(ws.activeProject.id == p.id)
    #expect(ws.activeProject.rootPath == "/tmp/web")
}

@Test func eachProjectHasOwnTabList() {
    let ws = WorkspaceModel()
    let a = ws.activeProject.tabList
    _ = ws.addProject(name: "b", rootPath: "/tmp/b")
    let b = ws.activeProject.tabList
    #expect(a !== b)  // distinct TabList instances
}

@Test func removingProjectBeforeActiveStepsBack() {
    let ws = WorkspaceModel()
    _ = ws.addProject(name: "b", rootPath: "/b")
    _ = ws.addProject(name: "c", rootPath: "/c")   // 3 projects, active = 2
    ws.removeProject(at: 0)
    #expect(ws.projects.count == 2)
    #expect(ws.activeIndex == 1)
}

@Test func removingLastRemainingProjectIsNoOp() {
    let ws = WorkspaceModel()
    ws.removeProject(at: 0)
    #expect(ws.projects.count == 1)
}

@Test func togglePinFlips() {
    let ws = WorkspaceModel()
    #expect(ws.projects[0].isPinned == false)
    ws.togglePin(at: 0)
    #expect(ws.projects[0].isPinned == true)
}

@Test func selectClampsToValid() {
    let ws = WorkspaceModel()
    ws.select(index: 5)
    #expect(ws.activeIndex == 0)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter WorkspaceModelTests` → FAIL (types not found).

- [ ] **Step 3: Implement**

```swift
// Sources/QuerttyCore/Model/WorkspaceModel.swift
import Foundation

public final class ProjectRuntime {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public var isPinned: Bool
    public let tabList: TabList

    public init(id: UUID = UUID(), name: String, rootPath: String,
                isPinned: Bool = false, tabList: TabList = TabList()) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isPinned = isPinned
        self.tabList = tabList
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
    }

    public var activeProject: ProjectRuntime { projects[activeIndex] }
    public var activeTabList: TabList { projects[activeIndex].tabList }

    @discardableResult
    public func addProject(name: String, rootPath: String) -> ProjectRuntime {
        let p = ProjectRuntime(name: name, rootPath: rootPath)
        projects.append(p)
        activeIndex = projects.count - 1
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
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WorkspaceModelTests` → PASS (7). Then `swift test` → full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuerttyCore/Model/WorkspaceModel.swift Tests/QuerttyCoreTests/WorkspaceModelTests.swift
git -c commit.gpgsign=false commit -m "feat(core): WorkspaceModel — projects (each owns a TabList) with add/remove/pin/select"
```

---

### Task 2: Multi-project persistence (QuerttyCore, TDD)

**Files:**
- Modify: `Sources/QuerttyCore/Persistence/SessionSnapshot.swift` (add workspace-model mapping)
- Create: `Tests/QuerttyCoreTests/WorkspaceModelSnapshotTests.swift`

**Interfaces:**
- Consumes: `WorkspaceModel`/`ProjectRuntime` (Task 1), `TabList`, `Workspace`/`Project`/`Session`/`Tab`/`Layout` (existing).
- Produces (add to `SessionSnapshot`):
  - `static func workspace(from model: WorkspaceModel) -> Workspace` — each `ProjectRuntime` → a `Project(name:rootPath:isPinned:sortOrder:sessions:)` whose single default `Session` holds the project's `tabList.trees` mapped to `[Tab]`. Persist active project via `Project.sortOrder` convention OR a documented field — for v1, persist order = array order and record the active index by setting the active project's `sortOrder = 0` rule is fragile; instead store active index in `Workspace.schemaVersion`? No — add nothing lossy: encode active project as the FIRST project is wrong too. **Decision:** persist project order as array order; do NOT persist active-project index in v1 (restored workspace activates project 0). This matches the tabs-activeIndex deferral. Note it.
  - `static func projectRuntimes(from workspace: Workspace) -> [ProjectRuntime]` — each `Project` → a `ProjectRuntime` (name/rootPath/isPinned + a `TabList` restored from its session's tabs via the existing `paneTrees`-style mapping). Empty → `[]`.

- [ ] **Step 1: Write the failing round-trip test**

```swift
// Tests/QuerttyCoreTests/WorkspaceModelSnapshotTests.swift
import Testing
@testable import QuerttyCore
import Foundation

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func workspaceModelRoundTripsThroughStore() throws {
    let model = WorkspaceModel()                                   // project 0 = home
    let p = model.addProject(name: "web", rootPath: "/tmp/web")    // project 1
    p.isPinned = true
    // give project 1 a split in its first tab
    let s2 = Surface(workingDir: "/tmp/web/api")
    _ = p.tabList.activeTree.splitFocused(direction: .vertical, newSurface: s2)
    model.select(index: 0)

    let store = WorkspaceStore(directory: try tempDir())
    try store.save(SessionSnapshot.workspace(from: model))

    let restored = SessionSnapshot.projectRuntimes(from: try store.load())
    #expect(restored.count == 2)
    #expect(restored[1].name == "web")
    #expect(restored[1].rootPath == "/tmp/web")
    #expect(restored[1].isPinned == true)
    let webDirs = restored[1].tabList.trees[0].layout.surfaces.map(\.workingDir)
    #expect(webDirs.contains("/tmp/web/api"))
}

@Test func projectRuntimesFromEmptyWorkspaceIsEmpty() {
    #expect(SessionSnapshot.projectRuntimes(from: Workspace()).isEmpty)
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter WorkspaceModelSnapshot` → FAIL.

- [ ] **Step 3: Implement the mapping**

Add the two functions to `SessionSnapshot`, reusing the existing tab↔layout logic. `workspace(from:)`: map each `ProjectRuntime` → `Project(name:rootPath:isPinned:sortOrder:<arrayIndex>:sessions:[Session(title:"main",tabs: tabList.trees.map { Tab(title:"", layout:$0.layout) })])`. `projectRuntimes(from:)`: for each `Project`, build `[PaneTree]` from `project.sessions.first?.tabs` (each `Tab.layout` → `PaneTree(layout:focusedSurfaceID: first surface)`), then `ProjectRuntime(name:rootPath:isPinned:tabList: TabList(restoring: trees) ?? TabList())`. Read the existing `SessionSnapshot` to reuse its helpers; keep functions pure.

- [ ] **Step 4: Run to verify pass + full suite**

Run: `swift test --filter WorkspaceModelSnapshot` → PASS, then `swift test` → green.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuerttyCore/Persistence/SessionSnapshot.swift Tests/QuerttyCoreTests/WorkspaceModelSnapshotTests.swift
git -c commit.gpgsign=false commit -m "feat(core): persist multiple projects (each with its tabs) round-trip via WorkspaceStore"
```

---

### Task 3: `SidebarView` (app, build + manual)

**Files:**
- Create: `App/Sources/App/SidebarView.swift`

**Interfaces:**
- Consumes: nothing from QuerttyCore directly except project display data (pass plain `(name, isPinned)` + selected index in; report actions out via closures — keep the view dumb).
- Produces: `final class SidebarView: NSView` with `var onSelect: ((Int) -> Void)?`, `var onAddProject: (() -> Void)?`, `var onTogglePin: ((Int) -> Void)?`; `func update(projects: [(name: String, isPinned: Bool)], selectedIndex: Int)`.

- [ ] **Step 1: Build the sidebar**

Implement `SidebarView` with an `NSTableView` (single column, view-based) inside an `NSScrollView`, showing each project's name + a pin affordance (e.g. a 📌 / SF Symbol toggle button per row or a context action), and an "Add Project" (+) button at the bottom. Row selection → `onSelect`; + button → `onAddProject`; pin toggle → `onTogglePin`. Highlight the selected row. Fixed width ~200pt. Discovery: use a view-based `NSTableView` with a simple cell (label + pin button); reference standard AppKit table patterns.

- [ ] **Step 2: Build**

Run: `mise exec -- tuist generate --no-open && tuist build quertty` → Build Succeeded (the view isn't wired into the window yet — that's Task 4; this task just compiles the component). If unused-symbol warnings block, wire it minimally in Task 4.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/App/SidebarView.swift
git -c commit.gpgsign=false commit -m "feat(app): SidebarView — project list with select/add/pin callbacks"
```

---

### Task 4: Integrate sidebar + projects into the window (app, build + manual + user verify)

**Files:**
- Modify: `App/Sources/App/TerminalViewController.swift` (own a `WorkspaceModel`; render active project's `TabList`; host `SidebarView` left of the tab/pane area; add-project via `NSOpenPanel`; prune registry across all projects)
- Modify: `App/Sources/App/AppDelegate.swift` (persistence: load `WorkspaceModel` on launch, save on terminate; menu item "Add Project…" ⌘O)
- Modify: `docs/phase1-acceptance.md`

**Interfaces:**
- Consumes: `WorkspaceModel` (Task 1), `SessionSnapshot` multi-project mapping (Task 2), `SidebarView` (Task 3), existing `SurfaceRegistry`/`TabList`/rendering.
- Produces: a window with a left sidebar of projects; selecting a project swaps the tab/pane area to that project's `TabList`; add-project opens a directory picker; pins persist; the whole workspace restores on relaunch.

- [ ] **Step 1: TVC owns a `WorkspaceModel`**

Replace TVC's `private var tabList = TabList()` with `private var workspace = WorkspaceModel()`. The computed `paneTree` now forwards to `workspace.activeTabList.activeTree`. All tab actions operate on `workspace.activeTabList`. Add `restore(workspace:)` (replaces the model) + `currentWorkspace` accessor (for save). Update the registry union-prune to span **all projects' all tabs**: `Set(workspace.projects.flatMap { $0.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) } })`.

- [ ] **Step 2: Host the sidebar + wire actions**

Add a `SidebarView` pinned to the left (width ~200), with the tab bar + pane area filling the rest (use an `NSSplitView` or constraints). Wire: `onSelect` → `workspace.select(index:)` + rebuild + refresh; `onTogglePin` → `workspace.togglePin(at:)` + refresh; `onAddProject` → present `NSOpenPanel` (`canChooseDirectories = true`, files off), and on choose: `workspace.addProject(name: url.lastPathComponent, rootPath: url.path)` + rebuild + refresh. A `refreshSidebar()` maps `workspace.projects` → `[(name, isPinned)]` + `activeIndex`. Selecting a project rebuilds the pane area from `workspace.activeTabList`.

- [ ] **Step 3: Menu + persistence wiring**

Add "Add Project…" (⌘O) to the menu (routes to a TVC `@objc addProject(_:)`). In `AppDelegate`: on launch, load workspace JSON → `SessionSnapshot.projectRuntimes(from:)` → `WorkspaceModel(restoring:)` → `tvc.restore(workspace:)` (fresh fallback if empty/corrupt — catch the throw). On terminate, `SessionSnapshot.workspace(from: tvc.currentWorkspace)` → save. (This supersedes Task 6's single-project save/load — replace those calls.)

- [ ] **Step 4: Build + manual check**

Run: `mise exec -- tuist generate --no-open && tuist build quertty` → Build Succeeded. Append a Task-4 section to `docs/phase1-acceptance.md` (PENDING USER VERIFICATION): sidebar lists projects; ⌘O adds a project (dir picker); clicking a project swaps to its tabs/splits; pin toggles + persists; quit/relaunch restores all projects + their layouts. The controller will run a synthesized/launch smoke and the user does the on-screen pass.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/App/TerminalViewController.swift App/Sources/App/AppDelegate.swift docs/phase1-acceptance.md
git -c commit.gpgsign=false commit -m "feat(app): projects sidebar — switch/add/pin projects, each with its own tabs, persisted"
```

---

## Self-Review

**Spec coverage:**
- Sidebar lists projects; project owns its tabs/splits → Tasks 1, 3, 4. ✓
- Add (dir picker) / pin / switch → Task 4 (+ model in Task 1). ✓
- Persist all projects + layouts across launches → Task 2 (mapping) + Task 4 (lifecycle). ✓
- Session preservation across project switch (union-prune all projects) → Task 4 constraint. ✓
- **Deferred:** AI agent status icons in the sidebar (Plan A — `2026-06-25-quertty-agent-detection.md`); Project→Session as a separate UI level (collapsed into tabs for now); persisting active-project index + active-tab index + focused surface (all open minor items); lazy-spawn for many-project scaling.

**Placeholder scan:** Tasks 1–2 (QuerttyCore) have complete code. Tasks 3–4 are app/UI integration whose exact AppKit table/NSOpenPanel/`NSSplitView` calls are flagged for standard-pattern implementation + discovery, each ending in a concrete build command + manual acceptance. No fabricated APIs.

**Type consistency:** `ProjectRuntime(id:name:rootPath:isPinned:tabList:)`, `WorkspaceModel` (`projects`/`activeIndex`/`activeProject`/`activeTabList`/`addProject(name:rootPath:)`/`removeProject(at:)`/`select(index:)`/`togglePin(at:)`/`init?(restoring:activeIndex:)`), `SessionSnapshot.workspace(from:)`/`projectRuntimes(from:)`, `SidebarView` (`onSelect`/`onAddProject`/`onTogglePin`/`update(projects:selectedIndex:)`), TVC `restore(workspace:)`/`currentWorkspace` — consistent across tasks, built on existing `TabList`/`Workspace`/`WorkspaceStore`/`SessionSnapshot`/`SurfaceRegistry`.
