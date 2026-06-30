# quertty — Tab Naming + Sidebar Tree Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** (1) Auto-name each tab after the focused pane's terminal title (live), with a manual-rename override that persists. (2) Turn the sidebar into an outline where a project with 2+ tabs expands to show its tabs as sub-items; clicking a tab sub-item switches to that project+tab; the active project auto-expands.

**Architecture:** `PaneTree` gains an optional persisted `manualTitle`. A pure `TabTitle` helper computes the display name with precedence `manualTitle → focusedSurfaceTitle → workingDir basename → "Tab N"`. The app observes the focused pane's `GhosttyTerminal` `@Published title` (Combine) and refreshes the tab bar + sidebar on change. `SidebarView` becomes an `NSOutlineView` (projects → tab children). Manual rename = double-click → inline `NSTextField`.

**Tech Stack:** Swift 6, SPM (`QuerttyCore`) + Tuist app, AppKit, Combine, Swift Testing, `libghostty-spm` (`GhosttyTerminal`).

## Global Constraints

- `QuerttyCore` stays UI-free (Foundation only): `PaneTree.manualTitle` + the `TabTitle` precedence helper are pure + unit-tested. Title observation / outline view / rename UI live in the app.
- **Auto-name source = `GhosttyTerminal`'s `@Published title`** of the focused pane (command-accurate only with shell integration; fall back to working-dir basename, then "Tab N"). Do NOT attempt PTY-fd/libproc (not exposed by the package).
- **Manual rename wins** and persists (maps to the Codable `Tab.title`); auto titles are live (recomputed, not persisted).
- Sidebar: project expands to tab children ONLY when `tabList.trees.count >= 2`; single-tab projects render as a plain row. Active project auto-expands. Selecting a project row switches project (keeps its active tab); selecting a tab child switches project + that tab.
- Tests: `QuerttyCore` via Swift Testing (`@Test` names must be GLOBALLY UNIQUE across the test target — prior collisions broke the build). App via build + manual; Accessibility is granted for synthesized smoke. Remove any temp `NSLog` before committing.
- Reuse existing: `PaneTree`/`TabList`/`WorkspaceModel`/`SessionSnapshot`/`SurfaceRegistry`/`SidebarView`/`TabBarView`/`TerminalViewController`. Commits: frequent, clean, `git -c commit.gpgsign=false`. Build app: `mise exec -- tuist build quertty`.

---

### Task 1: `PaneTree.manualTitle` + `TabTitle` precedence + persistence (QuerttyCore, TDD)

**Files:**
- Modify: `Sources/QuerttyCore/Model/PaneTree.swift` (add `manualTitle`)
- Create: `Sources/QuerttyCore/Model/TabTitle.swift` (pure precedence helper)
- Modify: `Sources/QuerttyCore/Persistence/SessionSnapshot.swift` (map `manualTitle` ↔ `Tab.title`)
- Create: `Tests/QuerttyCoreTests/TabTitleTests.swift`
- Modify: `Tests/QuerttyCoreTests/...` (extend a persistence test to cover manualTitle round-trip)

**Interfaces:**
- `PaneTree` gains `public var manualTitle: String?` (default nil), Codable, in the memberwise init (keep existing init call sites compiling — give it a default).
- `enum TabTitle { static func display(manualTitle: String?, focusedSurfaceTitle: String?, workingDir: String?, index: Int) -> String }` — precedence: non-empty `manualTitle` → non-empty `focusedSurfaceTitle` → non-empty basename of `workingDir` → `"Tab \(index + 1)"`. Trims whitespace; treats empty/whitespace as absent.
- `SessionSnapshot`: when building `Tab` from a `PaneTree`, set `Tab.title = paneTree.manualTitle ?? ""`; when restoring, set `PaneTree.manualTitle = tab.title.isEmpty ? nil : tab.title`.

- [ ] **Step 1: Write failing tests**

```swift
// Tests/QuerttyCoreTests/TabTitleTests.swift
import Testing
@testable import QuerttyCore

@Test func tabTitlePrefersManual() {
    #expect(TabTitle.display(manualTitle: "mine", focusedSurfaceTitle: "vim", workingDir: "/x", index: 0) == "mine")
}
@Test func tabTitleUsesFocusedTitleWhenNoManual() {
    #expect(TabTitle.display(manualTitle: nil, focusedSurfaceTitle: "vim", workingDir: "/x/y", index: 0) == "vim")
}
@Test func tabTitleFallsBackToWorkingDirBasename() {
    #expect(TabTitle.display(manualTitle: nil, focusedSurfaceTitle: "  ", workingDir: "/Users/me/web", index: 0) == "web")
}
@Test func tabTitleFallsBackToPositional() {
    #expect(TabTitle.display(manualTitle: " ", focusedSurfaceTitle: nil, workingDir: nil, index: 2) == "Tab 3")
}
@Test func paneTreeManualTitleDefaultsNilAndIsCodable() throws {
    var t = PaneTree(layout: Layout(root: .leaf(Surface(workingDir: "/x"))))
    #expect(t.manualTitle == nil)
    t.manualTitle = "named"
    let data = try JSONEncoder().encode(t)
    let back = try JSONDecoder().decode(PaneTree.self, from: data)
    #expect(back.manualTitle == "named")
}
```

- [ ] **Step 2: Run → fail.** `swift test --filter TabTitle` (and the PaneTree test).

- [ ] **Step 3: Implement** `PaneTree.manualTitle` (add stored prop + default-nil in init), `TabTitle.display(...)` (with whitespace-trim/empty handling), and the `SessionSnapshot` manualTitle↔Tab.title mapping. Read the existing `SessionSnapshot` Tab-building code and thread `manualTitle` through both directions.

- [ ] **Step 4: Extend persistence round-trip test** — set `manualTitle` on a tab, save→load via `WorkspaceStore`, assert it survives. (Add to the existing `WorkspaceModelSnapshotTests` or `SessionSnapshotTests`; unique `@Test` name.)

- [ ] **Step 5: Run → pass.** `swift test` full suite green.

- [ ] **Step 6: Commit.** `git -c commit.gpgsign=false commit -m "feat(core): PaneTree.manualTitle + TabTitle precedence + persistence round-trip"`

---

### Task 2: Live focused-pane title → tab display name (app, build + manual)

**Files:**
- Modify: `App/Sources/App/SurfaceRegistry.swift` (expose a surface's live title)
- Modify: `App/Sources/App/TerminalViewController.swift` (observe focused surface title; compute tab titles via `TabTitle`; refresh tab bar)

**Interfaces:**
- `SurfaceRegistry` exposes the focused pane's `GhosttyTerminal` title for a `Surface` — discovery: find where `@Published var title` lives (the grep shows it on a controller/state type with `terminalDidChangeTitle` + `workingDirectory`). Expose either `title(for: Surface) -> String?` (snapshot) AND a Combine publisher / change callback, OR a closure the registry invokes on title change. Keep `@MainActor`.
- TVC: for the active tab, observe the focused surface's title; on change (and on focus/tab switch), recompute each tab's display title via `TabTitle.display(manualTitle: tree.manualTitle, focusedSurfaceTitle: <focused surface live title>, workingDir: <focused surface workingDir>, index:)` and call `tabBarView.update(titles:selectedIndex:)`.

- [ ] **Step 1: Discovery** — read `GhosttyTerminal` (`TerminalController` + its state) to find the exact access path to the live `title` (and `workingDirectory`) for a surface's controller, and how to subscribe (`$title` Combine publisher on an `ObservableObject`, or the `terminalDidChangeTitle` delegate). Record it in the report.
- [ ] **Step 2: Implement** the registry title accessor + a change signal; in TVC, subscribe to the focused pane's title (re-subscribe on focus/tab/project change), recompute titles, refresh the tab bar. Manual `manualTitle` (when set) short-circuits to that.
- [ ] **Step 3: Build** `mise exec -- tuist build quertty` → Build Succeeded.
- [ ] **Step 4: Manual/synth check** — append to `docs/phase1-acceptance.md` (PENDING USER): run a command (e.g. `vim`) in a pane and the tab name reflects the title (with shell integration), reverting on exit; bare shell falls back to dir/Tab N. (Synthesized smoke optional.)
- [ ] **Step 5: Commit.** `feat(app): auto-name tabs from focused pane's live terminal title`

---

### Task 3: Sidebar outline tree — projects → tab sub-items (app, build + manual)

**Files:**
- Modify: `App/Sources/App/SidebarView.swift` (NSTableView → NSOutlineView)
- Modify: `App/Sources/App/TerminalViewController.swift` (provide tree data; handle tab-child selection; auto-expand active project)

**Interfaces:**
- `SidebarView` becomes an `NSOutlineView`-backed view. New data shape: `update(projects: [SidebarProject], selection: SidebarSelection)` where `SidebarProject = (id, name, isPinned, tabs: [(index:Int, title:String)])` and `SidebarSelection` identifies the active project (+ active tab). Callbacks: `onSelectProject((Int)->Void)`, `onSelectTab((projectIndex:Int, tabIndex:Int)->Void)`, `onAddProject`, `onTogglePin((Int)->Void)`. A project item shows children only when `tabs.count >= 2`.
- TVC builds the tree from `workspace.projects` (each project's `tabList.trees` → tab titles via `TabTitle`); `onSelectProject` → `workspace.select`; `onSelectTab` → select project then `tabList.select(index:)` + rebuild; auto-expand the active project after `update`.

- [ ] **Step 1: Rewrite SidebarView** as a view-based `NSOutlineView` (dataSource/delegate for the 2-level tree; project rows with pin + add button; child rows = tab titles). Guard programmatic selection re-entrancy (the `isUpdating` flag pattern, already established). Keep it dumb (no QuerttyCore import — take plain data + report indices).
- [ ] **Step 2: Wire TVC** — `refreshSidebar()` builds `[SidebarProject]` with each project's tab titles; auto-expand active project; route `onSelectTab` to switch project+tab. Update on tab add/close/rename/title-change.
- [ ] **Step 3: Build** → Succeeded.
- [ ] **Step 4: Manual check** (PENDING USER): a project with 2+ tabs expands; clicking a tab child switches to it; single-tab project stays a plain row; active project auto-expands.
- [ ] **Step 5: Commit.** `feat(app): sidebar outline — projects expand to tab sub-items`

---

### Task 4: Double-click to rename a tab (app, build + manual)

**Files:**
- Modify: `App/Sources/App/TabBarView.swift` (double-click a segment → inline edit) and/or `App/Sources/App/SidebarView.swift` (double-click a tab child → edit)
- Modify: `App/Sources/App/TerminalViewController.swift` (apply rename → `tree.manualTitle` + persist-on-change + refresh)

**Interfaces:**
- A rename affordance: double-click the active tab in the tab bar (simplest single surface) → an inline `NSTextField` prefilled with the current display title; commit on Enter/blur → `onRenameTab((tabIndex:Int, newName:String)->Void)`; Esc cancels. Empty/whitespace input clears `manualTitle` (reverts to auto).
- TVC: set `workspace.activeTabList.trees[i].manualTitle = newName.isEmpty ? nil : newName`, refresh tab bar + sidebar. (Persistence already carries `manualTitle` via Task 1.)

- [ ] **Step 1: Implement** the double-click inline editor on the tab bar (NSSegmentedControl doesn't edit inline → overlay a temporary `NSTextField` over the segment, or switch the tab bar to custom buttons; pick the simpler working approach and note it). Wire `onRenameTab`.
- [ ] **Step 2: Wire TVC** rename handler (set manualTitle, refresh, the workspace saves on quit so it persists).
- [ ] **Step 3: Build** → Succeeded.
- [ ] **Step 4: Manual check** (PENDING USER): double-click a tab → rename → name sticks across tab switches and relaunch; clearing the name reverts to auto.
- [ ] **Step 5: Commit.** `feat(app): rename a tab via double-click (manualTitle override)`

---

## Self-Review

**Spec coverage:** manualTitle + auto-from-title precedence (Task 1, tested) ✓; live focused-pane title → tab name (Task 2) ✓; sidebar tree with multi-tab expansion + click-to-switch + auto-expand active (Task 3) ✓; double-click rename persisting (Tasks 1+4) ✓.

**Placeholder scan:** Task 1 is complete pure-Swift code/tests. Tasks 2–4 carry discovery (GhosttyTerminal `@Published title` access path; NSOutlineView; inline-edit-over-segment) flagged for implementation against the real APIs, each ending in a build + manual check. No fabricated APIs.

**Type consistency:** `PaneTree.manualTitle`, `TabTitle.display(manualTitle:focusedSurfaceTitle:workingDir:index:)`, `SidebarView.update(projects:selection:)` + `onSelectProject`/`onSelectTab`/`onAddProject`/`onTogglePin`/`onRenameTab`, `SurfaceRegistry.title(for:)` — consistent across tasks, built on existing `WorkspaceModel`/`TabList`/`SessionSnapshot`/`SurfaceRegistry`.

**Risk:** auto-name accuracy depends on shell integration setting the title (accepted, with fallbacks). The tab bar is currently an `NSSegmentedControl` — inline rename may require switching it to custom buttons (Task 4 notes the call).
