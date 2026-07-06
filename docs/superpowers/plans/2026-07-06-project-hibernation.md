# Project Hibernation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** [`docs/plans/2026-07-06-project-hibernation-design.md`](../../plans/2026-07-06-project-hibernation-design.md)

**Goal:** Let projects be hibernated (sessions/processes/panes freed, layout kept) and woken (fresh shells) — manually and automatically after idle-and-quiet — surviving relaunch.

**Architecture:** Pure `ZettyCore` pieces (a `HibernationPolicy` decision, `hibernate-after` config, persisted `isHibernated`, per-project opt-out) drive an app-layer engine that kills a project's zmx sessions via the existing `onSurfacesClosed` path and excludes hibernated projects from the surface prune-union.

**Tech Stack:** Swift, AppKit, swift-testing (`ZettyCore`), Tuist.

## Global Constraints

- **Keep `ZettyCore` pure** — no AppKit; the hibernate *decision* is pure, the session-killing/UI is app-layer.
- **Never hardcode a color** — sidebar hibernated styling reads `ZTheme` tokens.
- **No debug `NSLog`/`print`.** **Commits require Glen's approval** (stage + ask).
- **New core files** → `mise exec -- tuist generate --no-open` before build/test; `tuist clean` first if a bogus "Manifest not found …/AgentLogos" appears.
- **Core tests:** `swift test`. **App build:** `xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build`.
- **Tolerant decode:** `Project` (workspace.json) must decode old files lacking `isHibernated` (→ false).
- **Never hibernate the active project.** Waking spawns fresh shells (no startup-command re-injection).

---

### Task 1: `HibernationPolicy` (pure decision)

**Files:**
- Create: `Sources/ZettyCore/Model/HibernationPolicy.swift`
- Test: `Tests/ZettyCoreTests/HibernationPolicyTests.swift`

**Interfaces:**
- Produces: `enum HibernationPolicy { static func shouldHibernate(idleFor:hibernateAfter:isBusy:isActive:isHibernated:autoDisabled:) -> Bool }`

- [ ] **Step 1: Failing test**

```swift
// Tests/ZettyCoreTests/HibernationPolicyTests.swift
import Testing
@testable import ZettyCore

private func decide(idle: TimeInterval, after: TimeInterval = 600, busy: Bool = false,
                    active: Bool = false, hib: Bool = false, off: Bool = false) -> Bool {
    HibernationPolicy.shouldHibernate(idleFor: idle, hibernateAfter: after, isBusy: busy,
                                      isActive: active, isHibernated: hib, autoDisabled: off)
}

@Test func hibernatesWhenIdleAndQuiet() { #expect(decide(idle: 700)) }
@Test func notBeforeIdleThreshold()     { #expect(!decide(idle: 300)) }
@Test func neverWhenDisabled()          { #expect(!decide(idle: 9999, after: 0)) }
@Test func neverWhenActive()            { #expect(!decide(idle: 9999, active: true)) }
@Test func neverWhenBusy()              { #expect(!decide(idle: 9999, busy: true)) }
@Test func neverWhenAlreadyHibernated() { #expect(!decide(idle: 9999, hib: true)) }
@Test func neverWhenOptedOut()          { #expect(!decide(idle: 9999, off: true)) }
```

- [ ] **Step 2: Run → fail** — `swift test --filter HibernationPolicyTests` (undefined).

- [ ] **Step 3: Implement**

```swift
// Sources/ZettyCore/Model/HibernationPolicy.swift
import Foundation

/// Pure decision for auto-hibernating a project. Kept free of clocks and AppKit
/// so it's fully testable; the app supplies `idleFor`/`isBusy`.
public enum HibernationPolicy {
    public static func shouldHibernate(
        idleFor: TimeInterval,
        hibernateAfter: TimeInterval,
        isBusy: Bool,
        isActive: Bool,
        isHibernated: Bool,
        autoDisabled: Bool
    ) -> Bool {
        guard hibernateAfter > 0 else { return false }   // feature off
        guard !isActive, !isHibernated, !autoDisabled, !isBusy else { return false }
        return idleFor >= hibernateAfter
    }
}
```

- [ ] **Step 4: Run → pass.** `swift test --filter HibernationPolicyTests`
- [ ] **Step 5: Commit** — `feat(core): HibernationPolicy decision`

---

### Task 2: `hibernate-after` config key

**Files:**
- Modify: `Sources/ZettyCore/Config/AppConfig.swift` (property, init, parse, serialize + a duration parser)
- Test: `Tests/ZettyCoreTests/AppConfigTests.swift`

**Interfaces:**
- Produces: `AppConfig.hibernateAfter: TimeInterval` (seconds; `0` = off, default 0).

- [ ] **Step 1: Failing test** — append to `AppConfigTests.swift`:

```swift
@Test func configParsesHibernateAfter() {
    #expect(AppConfig.parse("").hibernateAfter == 0)                 // default off
    #expect(AppConfig.parse("hibernate-after = 60m").hibernateAfter == 3600)
    #expect(AppConfig.parse("hibernate-after = 2h").hibernateAfter == 7200)
    #expect(AppConfig.parse("hibernate-after = 90").hibernateAfter == 90)   // bare = seconds
    #expect(AppConfig.parse("hibernate-after = off").hibernateAfter == 0)
    #expect(AppConfig.parse("hibernate-after = garbage").hibernateAfter == 0)
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement.** Add property (near `checkUpdates`): `public var hibernateAfter: TimeInterval`; init param `hibernateAfter: TimeInterval = 0` + assignment. Parse case:

```swift
            case "hibernate-after":
                config.hibernateAfter = AppConfig.parseDuration(value)
```

Add a small parser (private static):

```swift
    /// "90"→90s, "60m"→3600, "2h"→7200, "off"/"0"/invalid→0.
    static func parseDuration(_ raw: String) -> TimeInterval {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty || s == "off" || s == "false" { return 0 }
        let unit = s.last
        let numberPart = (unit == "m" || unit == "h" || unit == "s") ? String(s.dropLast()) : s
        guard let value = Double(numberPart), value >= 0 else { return 0 }
        switch unit {
        case "h": return value * 3600
        case "m": return value * 60
        default:  return value   // seconds
        }
    }
```

Serialize (near `check-updates = …`):

```swift
        # Auto-hibernate a project after it's idle and quiet (0 = off, e.g. 60m).
        hibernate-after = \(hibernateAfter == 0 ? "off" : "\(Int(hibernateAfter))")
```

> Round-trip note: serialized `off`/seconds both re-parse correctly.

- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** — `feat(core): hibernate-after config key`

---

### Task 3: Persisted `isHibernated` (model + snapshot, tolerant decode)

**Files:**
- Modify: `Sources/ZettyCore/Model/WorkspaceModel.swift` (ProjectRuntime)
- Modify: `Sources/ZettyCore/Model/Project.swift` (persisted struct + tolerant `init(from:)`)
- Modify: `Sources/ZettyCore/Persistence/SessionSnapshot.swift` (both directions)
- Test: `Tests/ZettyCoreTests/SessionSnapshotTests.swift` (or PersistenceTests)

**Interfaces:**
- Produces: `ProjectRuntime.isHibernated: Bool`, `Project.isHibernated: Bool` (tolerant), round-tripped.

- [ ] **Step 1: Failing test** — add to the snapshot/persistence tests:

```swift
@Test func workspaceRoundTripsHibernatedFlag() throws {
    let ws = WorkspaceModel(restoring: [ProjectRuntime(name: "a", rootPath: "/a")], activeIndex: 0)!
    ws.projects[0].isHibernated = true
    let snap = SessionSnapshot.workspace(from: ws)
    let data = try JSONEncoder().encode(snap)
    let decoded = try JSONDecoder().decode(Workspace.self, from: data)
    #expect(decoded.projects[0].isHibernated == true)
    let runtimes = SessionSnapshot.projectRuntimes(from: decoded)
    #expect(runtimes[0].isHibernated == true)
}

@Test func projectDecodesWithoutHibernatedField() throws {
    // Old workspace.json without the field → false, not a decode error.
    let json = #"{"id":"\#(UUID().uuidString)","name":"a","rootPath":"/a","isPinned":false,"sortOrder":0,"preserveSessions":false,"sessions":[]}"#
    let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
    #expect(p.isHibernated == false)
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement.**

`WorkspaceModel.swift` — add to `ProjectRuntime`:
```swift
    public var isHibernated: Bool
```
init param `isHibernated: Bool = false` + `self.isHibernated = isHibernated`.

`Project.swift` — add `public var isHibernated: Bool`, init param `isHibernated: Bool = false` + assignment, and a **tolerant `init(from:)`** (synthesized encode still includes it):
```swift
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        preserveSessions = try c.decodeIfPresent(Bool.self, forKey: .preserveSessions) ?? false
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        isHibernated = try c.decodeIfPresent(Bool.self, forKey: .isHibernated) ?? false
    }
```
(Add `private enum CodingKeys: String, CodingKey { case id, name, rootPath, isPinned, sortOrder, preserveSessions, sessions, isHibernated }` if not synthesized-compatible.)

`SessionSnapshot.swift` — carry the flag both ways:
- in `workspace(from:)`'s `Project(...)`: add `isHibernated: runtime.isHibernated,`
- in `projectRuntimes(from:)`'s `ProjectRuntime(...)`: add `isHibernated: project.isHibernated`

- [ ] **Step 4: Run → pass.** `swift test --filter "SessionSnapshotTests|PersistenceTests"`
- [ ] **Step 5: Commit** — `feat(core): persist project isHibernated (tolerant decode)`

---

### Task 4: Per-project auto-hibernate opt-out

**Files:**
- Modify: `Sources/ZettyCore/Settings/ProjectSettings.swift` (field + init + decode)
- Modify: `App/Sources/App/ProjectSettingsSheet.swift` (a tri-state control in General)
- Test: `Tests/ZettyCoreTests/ProjectSettingsTests.swift`

**Interfaces:**
- Produces: `ProjectSettings.autoHibernate: Bool?` (nil = follow global, false = never auto).

- [ ] **Step 1: Failing test** — append:

```swift
@Test func projectSettingsRoundTripsAutoHibernate() throws {
    var s = ProjectSettings(); s.autoHibernate = false
    let decoded = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(s))
    #expect(decoded.autoHibernate == false)
    #expect(ProjectSettings().autoHibernate == nil)   // default follow-global
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement.** In `ProjectSettings`: add `public var autoHibernate: Bool?`, init param, assignment, and `autoHibernate = try c.decodeIfPresent(Bool.self, forKey: .autoHibernate)` in `init(from:)`. In `ProjectSettingsSheet` General tab add a tri-state "Auto-hibernate" segmented control (Follow Global / On / Off) mirroring `preserveControl`, and persist it in `saveClicked` (`edited.autoHibernate = triStateValue(autoHibernateControl)`).

- [ ] **Step 4: Run → pass; app builds.**
- [ ] **Step 5: Commit** — `feat(core+app): per-project auto-hibernate override`

---

### Task 5: Hibernate / wake actions (kill sessions, exclude from prune, wake fresh)

**Files:**
- Modify: `App/Sources/App/TerminalViewController.swift` (`allSurfaceIDs`, `hibernateProject`, `wakeProject`, select-wakes)

**Interfaces:**
- Consumes: `onSurfacesClosed`, `rebuildSurfaceNodeView`, `onWorkspaceDidChange`, `workspace`.
- Produces: `func hibernateProject(_ project: ProjectRuntime, confirmIfBusy: Bool)`, `func wakeProject(_ project: ProjectRuntime)`.

- [ ] **Step 1: Exclude hibernated projects from the prune-union**

```swift
    var allSurfaceIDs: [UUID] {
        workspace.projects.filter { !$0.isHibernated }.flatMap { project in
            project.tabList.trees.flatMap { tree in tree.layout.surfaces.map(\.id) }
        }
    }
```

- [ ] **Step 2: Hibernate / wake methods**

```swift
    /// Frees a project's sessions, processes, and panes; keeps its layout.
    /// Never hibernates the active project (switches away first).
    func hibernateProject(_ project: ProjectRuntime, confirmIfBusy: Bool = true) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == project.id }),
              workspace.projects.count > 1, !project.isHibernated else { return }
        let surfaceIDs = project.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }
        if confirmIfBusy, !confirmClosingBusyPanes(surfaceIDs, what: "project “\(project.name)”") { return }

        if index == workspace.activeIndex {
            // Switch to the nearest non-hibernated project before freeing this one.
            guard let target = nearestAwakeProjectIndex(excluding: index) else { return }
            workspace.activeIndex = target
        }
        project.isHibernated = true
        onSurfacesClosed?(surfaceIDs)          // kill zmx sessions
        onActiveProjectChanged?()
        refreshTabBar(); refreshSidebar()
        rebuildSurfaceNodeView()               // prune tears down its surfaces
        onWorkspaceDidChange?()
        if let focused = focusedTerminalView() { view.window?.makeFirstResponder(focused) }
    }

    /// Wakes a hibernated project: fresh shells at each pane's cwd, layout intact.
    func wakeProject(_ project: ProjectRuntime) {
        guard project.isHibernated,
              let index = workspace.projects.firstIndex(where: { $0.id == project.id }) else { return }
        project.isHibernated = false
        workspace.activeIndex = index
        onActiveProjectChanged?()
        refreshTabBar(); refreshSidebar()
        rebuildSurfaceNodeView()               // re-creates surfaces → fresh shells
        onWorkspaceDidChange?()
        if let focused = focusedTerminalView() { view.window?.makeFirstResponder(focused) }
    }

    private func nearestAwakeProjectIndex(excluding index: Int) -> Int? {
        workspace.projects.indices.first { $0 != index && !workspace.projects[$0].isHibernated }
    }
```

- [ ] **Step 3: Selecting a hibernated project wakes it.** Where `sidebar.onSelectProject` is wired, if the target project `isHibernated`, call `wakeProject` instead of a plain activate:

```swift
        sidebar.onSelectProject = { [weak self] index in
            guard let self, self.workspace.projects.indices.contains(index) else { return }
            let project = self.workspace.projects[index]
            if project.isHibernated { self.wakeProject(project) }
            else { self.selectProject(at: index) }   // existing activate path
        }
```
(Use the existing project-select method name; if it's inline, factor the activate body into `selectProject(at:)`.)

- [ ] **Step 4: Build** → `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** — `feat(app): hibernate/wake projects (free sessions, keep layout)`

---

### Task 6: Sidebar affordances (dimmed + moon glyph, context menu, palette)

**Files:**
- Modify: `App/Sources/App/SidebarView.swift` (`SidebarProject.isHibernated`, dim + `moon.zzz` glyph, Hibernate/Wake menu items + callbacks)
- Modify: `App/Sources/App/TerminalViewController.swift` (populate `isHibernated`, wire `onHibernateProject`/`onWakeProject`, palette entries)

**Interfaces:**
- Consumes: `hibernateProject`/`wakeProject` (Task 5).

- [ ] **Step 1: Model + render.** Add `let isHibernated: Bool` to `SidebarProject`. In the row render, when hibernated: glyph = `NSImage(systemSymbolName: "moon.zzz", …)`, and dim the row (name/glyph `alphaValue`/color → `fg3`). Populate it in the TVC's `SidebarProject(...)` construction (`isHibernated: project.isHibernated`).

- [ ] **Step 2: Context menu.** In `menuNeedsUpdate` (where Rename/Settings/Remove items are built), add a Hibernate/Wake item toggled by state:

```swift
        let hibernate = NSMenuItem(
            title: projects[p].isHibernated ? "Wake Project" : "Hibernate Project",
            action: #selector(hibernateMenuClicked(_:)), keyEquivalent: "")
        hibernate.target = self
        hibernate.tag = p
        menu.addItem(hibernate)
```
plus `@objc private func hibernateMenuClicked(_:)` → `onToggleHibernate?(index)`, and a `var onToggleHibernate: ((Int) -> Void)?`. The TVC wires it to hibernate or wake based on state. (Add `isHibernated` to the `SidebarProject` list the sidebar holds so the menu can read it.)

- [ ] **Step 3: Palette.** Add to `buildCommands()`:
```swift
            PaletteCommand(glyph: "☾", label: "Hibernate / Wake Project", kbd: "") { [weak self] in
                guard let self else { return }
                let p = self.workspace.projects[self.workspace.activeIndex]
                // Active project → hibernate switches away; a hibernated one won't be active.
                self.hibernateProject(p)
            },
```

- [ ] **Step 4: Build + verify live** — hibernate a project via right-click: sidebar row dims + moon; `zmx list` shows its sessions gone; click it → wakes with fresh shells.
- [ ] **Step 5: Commit** — `feat(app): sidebar hibernate/wake affordances`

---

### Task 7: Auto-hibernation engine

**Files:**
- Modify: `App/Sources/App/TerminalViewController.swift` (lastActiveAt tracking, isBusy, timer) + `AppDelegate.swift` (config → hibernateAfter, per-project opt-out resolve)

**Interfaces:**
- Consumes: `HibernationPolicy` (Task 1), `appConfig.hibernateAfter` (Task 2), `foregroundBySurface`, agent status, `resolvedSettings(...).autoHibernate` (Task 4), `hibernateProject`.

- [ ] **Step 1: Track last-active per project.** Add `private var lastActiveAt: [UUID: Date] = [:]`; set `lastActiveAt[activeProject.id] = Date()` whenever the active project changes (in the select/activate path and on launch). Use a monotonic-ish `Date()`; it's fine for minute-scale id<le.

- [ ] **Step 2: Busy check.**

```swift
    private func projectIsBusy(_ project: ProjectRuntime) -> Bool {
        let ids = Set(project.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) })
        // A non-empty foreground command (not a bare shell) or a live agent = busy.
        for id in ids where !(foregroundBySurface[id] ?? "").isEmpty { return true }
        return project.tabList.trees.contains { tree in
            tree.layout.surfaces.contains { agentStatusBySurface[$0.id] == .running
                || agentStatusBySurface[$0.id] == .needsAttention }
        }
    }
```
(Use whatever the TVC's per-surface agent-status map is named; if none, gate on `foregroundBySurface` alone for v1 and note it.)

- [ ] **Step 2b: Provider for per-project opt-out + timeout.** Add `var autoHibernateConfig: (() -> (after: TimeInterval, disabled: (ProjectRuntime) -> Bool))?` wired from AppDelegate:
```swift
        tvc.autoHibernateAfter = { [weak self] in self?.appConfig.hibernateAfter ?? 0 }
        tvc.autoHibernateDisabled = { [weak self] project in
            self?.resolvedSettings(for: project).autoHibernate == false
        }
```
(Two simple closures on the TVC.)

- [ ] **Step 3: Timer.** Start a 60s repeating timer (when `autoHibernateAfter() > 0`; also re-evaluated on config reload). Each tick:
```swift
    private func evaluateAutoHibernation() {
        let after = autoHibernateAfter?() ?? 0
        guard after > 0 else { return }
        let now = Date()
        for project in workspace.projects where project.id != workspace.activeProject.id {
            let idle = now.timeIntervalSince(lastActiveAt[project.id] ?? now)
            if HibernationPolicy.shouldHibernate(
                idleFor: idle, hibernateAfter: after,
                isBusy: projectIsBusy(project), isActive: false,
                isHibernated: project.isHibernated,
                autoDisabled: autoHibernateDisabled?(project) ?? false) {
                hibernateProject(project, confirmIfBusy: false)   // policy already excluded busy
            }
        }
    }
```

- [ ] **Step 4: Build + verify live** — set `hibernate-after = 1m`, leave a quiet project unviewed >1m → it hibernates (sidebar dims, sessions gone); a project running a command does NOT; `hibernate-after = off` disables it; a per-project "Off" override is respected.
- [ ] **Step 5: Commit** — `feat(app): auto-hibernate idle, quiet projects`

---

## Self-Review

**Spec coverage:** stop-everything hibernate (Task 5 kills sessions + prune tears down surfaces) ✓ · layout kept / wake fresh (Task 5) ✓ · persist across relaunch (Task 3 + prune excludes hibernated so they stay cold) ✓ · auto idle+quiet (Tasks 1,7; `isBusy` guard) ✓ · config `hibernate-after` (Task 2) ✓ · per-project opt-out (Task 4) ✓ · sidebar dim+moon / menu / palette (Task 6) ✓ · never hibernate active (Task 5) ✓ · busy-confirm on manual (Task 5) ✓.

**Placeholder scan:** app-layer steps reference existing names to match (`selectProject`, the per-surface agent-status map, sidebar menu construction) — the implementer wires to the actual symbols; all core code is complete. No TBD in logic.

**Type consistency:** `HibernationPolicy.shouldHibernate(idleFor:hibernateAfter:isBusy:isActive:isHibernated:autoDisabled:)`, `AppConfig.hibernateAfter`, `Project.isHibernated`/`ProjectRuntime.isHibernated`, `ProjectSettings.autoHibernate`, `hibernateProject(_:confirmIfBusy:)`/`wakeProject(_:)` — consistent across tasks.

**Upgrade safety:** `Project` gets a tolerant `init(from:)` so existing `workspace.json` (no `isHibernated`) still loads.
