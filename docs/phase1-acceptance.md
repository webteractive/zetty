# Phase 1 Acceptance Checklist

## Task 3: Recursive split rendering — SurfaceNodeView + PaneTree

### Manual check

To visually verify that two panes render side-by-side and are both interactive:

1. Open `App/Sources/App/TerminalViewController.swift`.
2. Change the `debugTwoPane` flag to `true`:
   ```swift
   private static let debugTwoPane: Bool = true
   ```
3. Regenerate and run the app:
   ```bash
   mise exec -- tuist generate
   open quertty.xcworkspace
   # Build & Run in Xcode (Cmd+R)
   ```
4. Observe that the window shows **two terminal panes side by side** (vertical split, 50/50).
5. Click into each pane and type — both should accept keyboard input and run a live shell.
6. Resize the window — both panes should resize proportionally.
7. Drag the divider — the split ratio should adjust interactively.
8. Revert `debugTwoPane` back to `false` before committing.

**Status: PENDING USER VERIFICATION**

---

### Build verification (headless)

Two-pane split compiles cleanly via:

```bash
mise exec -- tuist generate && mise exec -- tuist build quertty
```

Result: **Build Succeeded** (confirmed by automated build step).

---

## Task 4: Split / close / click-to-focus pane actions

### Manual checks

Run the app:
```bash
open ~/Library/Developer/Xcode/DerivedData/quertty-giuacqmlsqkgkrdadhyyjabydjxb/Build/Products/Debug/quertty.app
```

Or open `quertty.xcworkspace` in Xcode and press ⌘R.

1. **Split Vertically (⌘D)**: Press ⌘D — the window should split into two side-by-side panes. The newly created (right) pane should receive focus (accent border).
2. **Split Horizontally (⇧⌘D)**: With a pane focused, press ⇧⌘D — the focused pane should split top/bottom.
3. **Type in each pane independently**: Click into each terminal and type — input should go to the correct pane only.
4. **Surviving sessions keep their state**: After splitting, type something in the original pane, then close the other pane with ⌘W — the original pane should fill the space and retain all its scrollback/history.
5. **Close pane (⌘W)**: Press ⌘W — the focused pane closes and the sibling expands to fill. If only one pane remains, ⌘W is a no-op (last pane is preserved).
6. **Click switches focus**: In a multi-pane layout, click on a non-focused pane — the accent border should move to the clicked pane and keypresses should go there.
7. **Focus indicator**: The focused pane has a 2-pt accent-coloured border; unfocused panes have a thin separator-coloured border (0.5 pt).

**Status: PENDING USER VERIFICATION**

### Build verification (headless)

```bash
mise exec -- tuist generate && mise exec -- tuist build quertty
```

Result: **Build Succeeded** (confirmed by automated build step).

---

## Task 5: Tabs — one PaneTree per tab, tab bar, new/close/switch

### Manual checks

Run the app:
```bash
open ~/Library/Developer/Xcode/DerivedData/quertty-giuacqmlsqkgkrdadhyyjabydjxb/Build/Products/Debug/quertty.app
```

Or open `quertty.xcworkspace` in Xcode and press ⌘R.

1. **Tab bar visible**: The window should show a 28-pt tab bar strip above the pane area, with one segment labelled "Tab 1" and a "+" button to its right.
2. **New Tab (⌘T)**: Press ⌘T — a second segment "Tab 2" appears; the pane area resets to a fresh single-pane terminal. Pressing ⌘T again gives "Tab 3".
3. **Split within a tab (⌘D)**: While on Tab 2, press ⌘D to split vertically. Switch to Tab 1 (⌘{) — it should still show its original single pane. Switch back to Tab 2 — the split should still be present.
4. **Live sessions survive tab switch**: Type text in a pane on Tab 1, switch to Tab 2 and back — the text and shell history on Tab 1 must be intact (background sessions are never pruned).
5. **Close Tab (⇧⌘W)**: With Tab 2 active and a split inside it, press ⇧⌘W — Tab 2 disappears, remaining tabs reindex, and the pane area shows the next available tab's layout.
6. **Close Tab no-op on last tab**: With only one tab open, ⇧⌘W must be a no-op (tab stays).
7. **Select Next Tab (⌘})**: Cycles forward through tabs, wrapping from the last back to Tab 1.
8. **Select Previous Tab (⌘{)**: Cycles backward through tabs, wrapping from Tab 1 to the last tab.
9. **Tab bar click**: Click a segment in the tab bar — the pane area should switch to that tab's layout.
10. **Focus indicator**: Within a tab, the focused pane retains its 2-pt accent border; switching tabs restores the correct focus highlight for that tab.

**Status: PENDING USER VERIFICATION**

---

### Build verification (headless)

```bash
mise exec -- tuist generate && mise exec -- tuist build quertty
```

Result: **Build Succeeded** (confirmed by automated build step).

---

## Task 6: Persist & restore layout via WorkspaceStore

### What was implemented

- `Sources/QuerttyCore/Persistence/SessionSnapshot.swift` — pure mapping functions:
  - `SessionSnapshot.workspace(from:)` — snapshots a `TabList` into a `Workspace` (all tabs under one default Project/Session).
  - `SessionSnapshot.paneTrees(from:)` — reverses the mapping; returns `[]` on empty/absent workspace so callers fall back gracefully.
- `Sources/QuerttyCore/Model/TabList.swift` — added `public convenience init?(restoring:activeIndex:)` that builds a `TabList` from saved `PaneTree`s; returns `nil` for an empty array.
- `Tests/QuerttyCoreTests/SessionSnapshotTests.swift` — 7 Swift Testing tests covering the round-trip (tab count, surface `workingDir`s survive save/load), empty-workspace fallback, and `TabList.init?(restoring:)` edge cases.
- `App/Sources/App/TerminalViewController.swift` — added `restore(trees:)` (seeds the `tabList` before the view loads) and `currentPaneTrees` (read-only snapshot for the quit path).
- `App/Sources/App/AppDelegate.swift` — wired lifecycle:
  - `applicationDidFinishLaunching`: loads `~/Library/Application Support/quertty/workspace.json`, maps to `PaneTree`s, seeds `TerminalViewController`. Falls back silently to a fresh tab on any error.
  - `applicationWillTerminate`: snapshots `currentPaneTrees` → `Workspace` → saves. Errors swallowed so quit path never crashes.

### Manual check

Open quertty, create a 2-tab arrangement (⌘T) with a vertical split on one tab (⌘D), quit (⌘Q), relaunch.

Expected:
- The same number of tabs is restored.
- The split layout on the tab that had a split is restored.
- Terminals re-spawn at the saved working directories.
- Scrollback is not restored (no daemon, expected).

**Status: PENDING USER VERIFICATION**

---

### Build verification (headless)

```bash
mise exec -- tuist generate && mise exec -- tuist build quertty
```

Result: **Build Succeeded** (confirmed by automated build step).

### Unit tests

```bash
swift test
```

Result: **38 tests passed** (all passing, including 7 new SessionSnapshot round-trip tests).

---

## Task 7: Projects sidebar — switch/add/pin projects, each with its own tabs, persisted

### What was implemented

- `App/Sources/App/TerminalViewController.swift` — replaced `private var tabList: TabList` with `private var workspace = WorkspaceModel()`. The `paneTree` computed property now forwards to `workspace.activeTabList.activeTree`. All tab actions (`newTab`, `closeTab`, `selectNextTab`, `selectPreviousTab`, `selectTab(at:)`) operate on `workspace.activeTabList`. Added `restore(workspace:)` (replaces the model) and `currentWorkspace` (read-only accessor for save). Replaced `restore(trees:)`/`currentPaneTrees` which are now superseded. Added `rebuildSurfaceNodeView()` union-prune over all projects × all tabs: `workspace.projects.flatMap { $0.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) } }`. Added `addProject(_:)` `@objc` responder target + `presentAddProjectPanel()` via `NSOpenPanel` (`canChooseDirectories=true`, `canChooseFiles=false`). Layout: sidebar (200 pt) + thin separator + content container side-by-side via Auto Layout constraints; tab bar and pane area are hosted inside the content container.
- `App/Sources/App/AppDelegate.swift` — replaced `restoreLayout(into:)`/`saveLayout()` with `restoreWorkspace(into:)`/`saveWorkspace()` using `SessionSnapshot.projectRuntimes(from:)` → `WorkspaceModel(restoring:)` → `tvc.restore(workspace:)` on launch, and `SessionSnapshot.workspace(from: tvc.currentWorkspace)` on terminate. Restoration is unconditional (no `preserveSessions` gate). Added "Add Project…" ⌘O menu item in a new "Project" menu. Default content size widened from 720→920 to accommodate the 200 pt sidebar.

### Manual check (PENDING USER VERIFICATION)

Run the app:
```bash
open ~/Library/Developer/Xcode/DerivedData/quertty-giuacqmlsqkgkrdadhyyjabydjxb/Build/Products/Debug/quertty.app
```

1. **Sidebar visible**: A 200-pt sidebar appears on the left with the default project listed (your home directory name). A "+" button sits at the bottom.
2. **Add Project (⌘O or "+")**: Press ⌘O or click "+" — a directory picker opens. Choose any directory — the project is added to the sidebar and becomes active with a fresh tab.
3. **Switch project**: Click a different project row in the sidebar — the tab bar and pane area swap to that project's own tabs/splits.
4. **Independent tabs per project**: Open multiple tabs (⌘T) in project A, switch to project B — it has its own separate tab set. Switch back to project A — original tabs are intact.
5. **Pin toggle**: Click the pin icon on a project row — it toggles between filled (pinned) and outline (unpinned).
6. **Persist across launches**: Add a second project, create tabs/splits in each, quit (⌘Q), relaunch — all projects, their tabs, and layouts are restored.
7. **Splits survive project switch**: Background projects' PTY sessions are never pruned (union-prune across all projects × all tabs).

**Status: PENDING USER VERIFICATION**

---

### Build verification (headless)

```bash
mise exec -- tuist generate --no-open && tuist build quertty
```

Result: **Build Succeeded** (confirmed by automated build step).
