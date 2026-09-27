---
paths:
    - "Sources/ZettyCore/Tiles/**"
    - "App/Sources/App/Tiles/**"
commands:
    - "zetty tiles"
triggers:
    - "changing tile mode, tile views, or tile profiles"
---

# Tile mode

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

⇧⌘G (also `Ctrl+B g`, the tab bar's grid button, **View → Tile Running
Sessions**, ⌘K, and `zetty tiles`) replaces the pane area with a grid of
**live, interactive terminals** drawn from every awake project. Designs:
`docs/superpowers/specs/2026-09-20-tile-mode-design.md` (rendering, reflow,
cost) and `2026-09-20-tile-profiles-design.md` (profiles, which superseded the
first one's membership model). Pure model in `ZettyCore/Tiles/`
(`TileProfile` · `TileResolution` · `TileProfileStore` · `TileGrid` ·
`TileMembership`), all unit-tested; AppKit in `App/Sources/App/Tiles/`
(`TileView` · `TileGridView` · `TileAttachPicker`).

**An open tile view IS its profile.** There is no template/instance split and
no save step: `mutateActiveTileProfile` is the ONLY writer, and it updates the
library and writes `tile-profiles.json` on every change. Closing a view's tab
leaves the profile in the library.

Eight things here will look like tidy-ups and are not:

- **The tiles are the registry's real `AppTerminalView`s**, so typing into a
  focused tile reaches its pty with no forwarding. That is also why a tile
  resizes the pty and every TUI in it reflows — accepted.
- **The grid is NOT window-area-bounded, and the first design argued it was.**
  Measured 2026-09-20 at 828x705: a 16-tile grid took the footprint from
  **87 MB at one live pane to 297 MB**, about **14 MB per extra pane**.
  `IOSurface` DID stay area-bounded (26.7 → 51.4 MB, 4 → 51 regions, ~1.6 MB
  per tile, exactly `pane_px x 4 x 3`), but `IOAccelerator (graphics)` did not
  (15.0 → 117.6 MB, 58 → 364 regions) — per-surface Metal state, not a render
  target, so a smaller pane does not shrink it.
- **A slot keys on canonical `rootPath` + `PaneTree.id`, and neither obvious
  alternative works.** Project *names* are not unique; a tab's display *title*
  is regenerated from its running agent every second; a tab's *index* shifts on
  reorder. `PaneTree.id` was added for this, decoded tolerantly. **`Tab.id` IS
  `PaneTree.id`** — `SessionSnapshot` threads it in both directions, and
  dropping it (as it did at first) makes every slot in every profile resolve as
  `.missing` after one relaunch.
- **The grid caps VISIBLE slots, never attachments.** `TileProfile.setGrid`
  never truncates past an attachment, so shrinking a profile's grid cannot drop
  a pane; it does trim trailing holes, so it leaves no phantom attach cells.
  The view scrolls past capacity.
- **The size comes from the ACTIVE PROFILE's grid**, not `zetty-tiles-grid` —
  that key only seeds a new view. Reading the global one there silently renders
  every profile at the default shape.
- **⌘W detaches, it does not close the pane**; ⇧⌘W closes the view. Killing the
  real pane stays on the tile's own menu, because doing it by accident from a
  grid of sixteen is expensive. Both are native menu equivalents, resolved
  before the surface sees them, so their `@objc` actions branch as well as the
  prefix layer.
- **Esc and ⏎ belong to the pty, never the grid** — "esc to interrupt" is
  Claude's own UI and ⏎ submits. The toggle is the only exit, and it always
  lands on the focused tile's pane.
- **Tile mode never changes the active project.** Moving focus across tiles
  would otherwise re-run `applyThemeForActiveProject()` per hop, and with
  per-project appearance overrides the app would flip dark/light as you arrow
  around. The status bar still follows the focused TILE
  (`statusBarSurface`).

**A layout is a TREE, not a grid.** `TileNode` (`.slot` / `.split`) is shaped
exactly like `SurfaceNode`, and `frames(in:)` mirrors `Layout.collectFrames`
over the same `LayoutRect` — so `1|2/3` is two splits, and anything else is
too. **Leaves in first-to-second order ARE the slot indices**, which is what
lets `TileProfile.slots` stay the flat array everything else is built on.
`TilesGrid` survives only as a CONSTRUCTOR (`TileNode.uniform`) behind the
sheet's steppers and `zetty-tiles-grid`.

- **Splitting inserts the new leaf at `index + 1`**, and `TileProfile.split`
  inserts a hole there to match. That alignment is the invariant the whole
  model turns on; it is tested directly.
- **Closing the only leaf is refused** — a view with no slots has nothing to
  show and no way back.
- **Dividers are addressed by their own index**, not a leaf's: a leaf has many
  ancestor splits and only one of them owns the handle being dragged.
- **A drag persists only on mouse-up** (`mutateActiveTileProfile(persist:)`).
  Writing through per mouse-move would save the library and rebuild the tab bar
  dozens of times a second.
- **Scrolling is gone, along with `TileGrid.layout`'s overflow maths.** A tree
  subdivides the space it is given, so it always fits; capacity is the leaf
  count. Do not reintroduce either.
- **Old libraries migrate silently**: a stored `grid` decodes to
  `TileNode.uniform`, and only `root` is ever written back, so a file converts
  itself the first time it is saved.
- **Named layouts are GONE, and so is `zetty-tiles-grid`.** Every preset was
  reachable by splitting one slot, and once a tile could be split and removed
  from its own face there was nothing left for a saved shape to save. A view is
  created directly by `+` as a single `.slot`; `TileLayout`, the chooser's
  layout cards, `New View from Layout`, `Remove Layout`, `Save as layout` and
  the columns-by-rows sheet are all deleted. `TileProfileFile` simply stops
  READING `layouts`/`seededLayoutNames`, so an old library converts itself on
  the next write — the same one-way migration the legacy `grid` key gets, and
  profiles in that file are untouched.
- **Deleting the `zetty-tiles-grid` case needed no `retiredReservedKeys`
  entry**, because the key is in the `zetty-` namespace and
  `isReservedButUnsupported` swallows that whole prefix. This is precisely why
  new keys must use it: the retired list exists for the grandfathered
  unprefixed ones. Regression-tested from both ends — the key is swallowed
  rather than forwarded, and it is dropped from `rendered()`.
- **`TileShapeImage` is all that survives of `TileConfigSheet`.** The chooser
  still draws an arrangement as its silhouette; it just no longer asks for one.

**A view is not a structure you choose, it is one you build.** Creating one
mints a single `.slot` and shows it; the shape comes from splitting the tiles
themselves. This replaced a sheet asking for columns and rows, which was asking
a question the first two clicks would change the answer to.

**⇧⌘G opens the CHOOSER, not a view.** `loadTileLibrary` no longer falls back
to opening the first profile, and `rebuildSurfaceNodeView` slots
`TileChooserView` in place of the grid whenever `openTileViews` is empty —
which is also where you land after closing your last view. Its labels are all
`.defaultLow` compressible, because it lives inside the main window and that is
the exact mistake that blocked the floor at 387pt.

**`newTileView` still takes a `then:` completion** even though it no longer
waits on a sheet, because `addSurfaceToTileView` composes with it: the
old straight-line version attached the pane to whichever profile was active
*before* the sheet, which is the previous one.

**Attaching FOCUSES what it attached**, through `attachAndFocus(_:at:)` —
the single owner of attach + focus + spawn. All four paths did those steps by
hand and none focused, so an attach left the keyboard on whatever tile was
selected before. Focus is read from the resolution AFTER the mutation (that is
what turns a slot into a surface id) and is set even though the pane has no pty
yet, because `focusTileFirstResponder` claims first responder once the spawn
queue brings it up.

**Three attach paths, one mutation.** The `+ Attach` cell opens
`TileAttachPicker` (a `CommandPaletteView`-shaped overlay reusing
`CommandSearch.rank`); a sidebar tab row can be dropped on a slot; and a pane's
right-click offers `Add to Tile View ▸`. All three call
`mutateActiveTileProfile { $0.attach(...) }`, so they cannot drift. The drop
lands on the GRID, outside the outline view, so `SidebarView.validateDrop` —
the rule protecting the pinned-first invariant — is never consulted.

**A slot can also be filled with a pane that does not exist yet.** The picker
returns a `TileAttachPicker.Action` rather than a `TileSlot`, and its second
case mints one: `attachNewTileSession` calls `tabList.newBackgroundTab()` and
attaches THAT through the same single mutation. Three things about it are
deliberate:

- **The agent chooser runs against the TARGET project.** `chooseAgentThenSpawn`
  read `workspace.projects[workspace.activeIndex]`, and tile mode never changes
  the active project — so a new session in one project would have been offered
  another's agents and account default. It now has a
  `chooseAgentThenSpawn(in:)` overload and the old signature is a wrapper.
  Cancel creates no tab and leaves the slot empty, which is that method's
  existing contract.
- **Both stamps land before the attach.** `accountID` and any startup command
  go onto the surface the moment `newBackgroundTab()` returns — the surface
  environment is read once, when libghostty creates the pane, so a stamp after
  the spawn describes a process that no longer matches.
- **The spawn belongs to the tile queue**, via `enqueueMissingTileSurfaces()`,
  NOT `spawnPaneInBackground`. A new session is one more pane the grid is
  bringing up and must be staggered with the rest — same reason
  `attachNextTileSurface` exists rather than `ensurePaneIsLive`.

**The new-session row sits with its own project's tabs**, not in a block at the
end. `CommandSearch.rank` breaks ties on the original index, so its position in
`tileAttachCandidates()` IS where a query naming the project puts it; collecting
them separately would strand every one of them below every tab.

**A fourth attach path adds a PROJECT.** The picker's `Add Project…` row (last,
for the same tie-break reason), the empty cell's `Add Project` row and — while
the grid is up — ⌘O / ⇧⌘N / sidebar `+` / palette all end in
`addProjectToTile(_:target:)`. `presentAddProjectPanel` takes an `onChosen`,
and `addProject(_:)` branches on `tileMode` at CHOOSE time (and closes an open
attach picker first — it would point at a slot the add may split away). The
sidebar's `+` goes through `addProject(nil)` for exactly this; it used to call
the panel directly and would have bypassed the redirect. Three things are
deliberate:

- **`activate: false`, always.** Activating would switch the project behind
  the grid — the invisible switch `320a61a` removed from sidebar clicks.
- **Cancelling the chooser still attaches a plain shell**, where New session's
  Cancel creates nothing: the folder panel has already committed a project,
  and leaving it unattached strands it. `chooseAgentThenSpawn(in:onCancel:)`
  carries that; every other caller passes no `onCancel`.
- **A layout template skips the chooser** (`insertProject` reports
  `usedTemplate`): the template already declares what its panes run.

**A slot is re-checked after the sheets.** The tile paths cross two
window-modal steps (folder panel, chooser) while a script can still reshape or
switch views, so `.slot` carries the view id and what the slot held
(`tileSlotTarget`), and `attachTab` attaches there only if
`TileProfile.isStillTarget` agrees — else it places by `TilePlacement`. If the
grid CLOSED meanwhile, nothing is dropped: a folder chosen from a tile's panel
is added the ordinary way, and a chooser that returns with the grid down still
stamps the pane and parks the tab in the active view in the background (no
spawn, no focus), like `zetty tiles attach` does.

A folder already in the workspace (`WorkspaceModel.projectIndex(forRoot:)`,
canonical-key compared, never matching scratch) is attached, not re-added; if
its tab is already in the view, both targets just focus that tile rather than
show it twice (`attachTab`). `stampAndAttach` is shared with New session, so
the stamp-before-spawn rule lives in one place.

**There is no All Running view.** Toggling into tile mode opens the CHOOSER;
an auto-filled view was what made the grid unreadable at sixteen tiles, and the
picker replaced it rather than joining it. `TileProfileKind` and
`TileMembership` were deleted with it, and `loadTileLibrary` drops a stored
"All Running" profile on read so an old library cleans itself up.

**Double-clicking a tile's HEADER leaves the grid for that pane.** It has to be
the header: the body is the terminal view, which consumes its own mouse events,
so a click there never reaches `TileView` at all.

**That same swallowed click is why focus is driven by the first-responder
KVO.** Clicking into a sibling tile never fires `TileView.mouseDown`, so
`handleFirstResponderChange` routes to `focusTile` in tile mode (and to
`focusChanged` otherwise, which only knows the active project's `paneTree`) —
without it the accent border stayed on the previous tile while typing went to
the new one. `focusTile` is therefore idempotent and skips re-asserting first
responder when the responder is already inside that pane, or it would re-enter
its own observation.

**A sidebar click focuses the tile, when there is one.** `onSelectProject` and
`onSelectTab` try `focusAttachedTile` first. For a tab row that is the tile
showing that tab. For a project row it is the tile of the project's active tab,
or else its first tile in slot order. When the view on screen has no such tile,
`leaveTileModeForSidebarClick` exits the grid and then `selectProject` runs.
On its own, `selectProject` switched the project BEHIND the grid, which was
invisible, and it pulled the keyboard off the focused tile. The exit clears
`tileFocusedSurfaceID` first, or `setTileMode(false)` would land on the focused
tile's pane and flash it on the way to the one that was clicked. `focusAttachedTile` then
calls `refreshSidebar()` so the highlight returns to the active project, which
tile mode never changes.

**⌘D / ⇧⌘D split the SLOT in tile mode**, they are not disabled there. The
reason they once were still holds — no pane tree is on screen, so splitting a
PANE would reshape the active project's layout out of sight — and splitting the
slot is precisely the thing that does not, so `splitVertical`/`splitHorizontal`
route to `splitFocusedTileSlot` rather than returning. `validateMenuItem` no
longer greys them, and the palette lists them in both modes named for what they
divide (`Split Slot Right` vs `Split Pane Right`) — "Split Pane" in a grid with
no pane tree would be a lie. The header icons and `Ctrl+B %` / `Ctrl+B "` reach
the same place.

**`prune` must spare the tiles, or a tile flickers out on every rebuild.**
`TileResolution` deliberately does NOT check hibernation — a slot keeps
pointing at its pane whatever the project is doing — but `allSurfaceIDs`
EXCLUDES hibernated projects. Pruning against that alone frees a tile's surface
the instant after `tileDescriptors()` created it: the tile renders
`.attaching`, `enqueueMissingTileSurfaces` re-creates it, and the next rebuild
frees it again. Every prune site therefore goes through
`retainedSurfaceIDs` (`allSurfaceIDs` + `tileFocusableIDs` while tile mode is
on) rather than `Set(allSurfaceIDs)`, so no site can forget. Attaching a pane
to a tile is an explicit request to see it, and that outranks hibernation's
claim on the memory — the sidebar still shows the project as dormant, which is
the lesser inconsistency. Reported as "opening the session manager makes the
pane say attaching", because the Sessions drawer's toggle calls
`rebuildSurfaceNodeView` — but ANY structural change did it.

**`focusTileFirstResponder` never takes the keyboard from a field editor.**
The grid calls it on every refresh, including the spawn queue's 2-second ticks,
and selecting a view queues its tiles. So a pill's double-click rename lost
focus, and with it committed, moments after opening, because the first click
had queued spawns. The guard also covers the tile manager's rename and the
command palette. Renaming a view from the strip goes through `renameTileView(at:)`,
which renames that view in place without selecting it. A blank name there is a
cancel, not an error: a view has no automatic name to fall back to.

**The grid survives `rebuildSurfaceNodeView`** (removed from the container,
instance kept), so a scheme change leaves everything `build()` coloured once in
the old palette. `TileGridView.applyTheme()` exists for that and is called from
`TerminalViewController.applyTheme()`; it forwards to each `TileView`, which is
why that one is internal rather than private. Same corollary as
`TabBarView.restyle()` and `SidebarView.rebuildOutline()`.

**The mode itself is persisted**, as `Workspace.tileModeActive` beside the open
view ids — not in the workspace MODEL, where a zoom would go. `restoreTileMode`
seeds a pending flag before the view loads and `viewDidLoad` enters through
`setTileMode(true)`, never by flipping the flag: the enter path is what seeds
focus and runs the pane spawn queue.

**Splitting has to be VISIBLE, because an empty cell is a whole Freeform
view.** A fresh Freeform view is one `.empty` cell, which builds no header —
so its only affordance was a `+ Attach` label, and splitting lived in a
right-click or `Ctrl+B %`. The empty cell now stacks Attach / Split Right /
Split Down, and a headered tile carries ONE button popping the slot menu it
already builds (not two of its own — the header is at capacity with the Open
pill, and two more glyphs come out of the title). Headered tiles need it as
much as empty ones: once both cells of a 2-slot view hold panes there are no
empty cells left, so empty-cell buttons alone dead-end after the first split.
Rows are stacked and labelled because two labels in a row need ~180pt and clip
in a 4x4 grid, and because a bare split glyph is not self-evident in the one
place a first-time user is looking for the answer.

**Removing a split is offered only when one exists, and only an EMPTY cell
can do it.** `TileNode.close` refuses the last leaf, so a fresh single-slot
Freeform view has nothing to collapse — `TileDescriptor.canRemove`
(`capacity > 1`) gates both the row and the menu item rather than letting
either sit there doing nothing. And because `removeTileSlot` branches on
whether the slot is filled (filled → detach the pane, leaving a hole; empty →
collapse the split), removal is inherently two-step from a filled tile. The
menu item is therefore titled for what it will actually do — **Detach Pane**
vs **Remove Split** — where both cases used to read "Remove Slot", which was
wrong for a filled tile: it does not remove the slot, it empties it.

**The empty cell's rows are `ClickRowView`, which CONSUMES its `mouseDown`.**
A plain `NSView` forwards it up the responder chain, so a row would reach
`TileView.mouseDown` as well and open the attach picker on top of the split. A
gesture recogniser was rejected for the same job: whether it swallows the
underlying event depends on `delaysPrimaryMouseButtonEvents`, and "Split Down
also opened the picker" must not rest on that.

**These controls are on EVERY tile, not just Freeform ones.** A profile COPIES
its layout tree with no back-link, so there is no way to ask which layout a
view came from — and the tree is a tree everywhere, so the affordance is right
everywhere.

**The tile header is uniform icons**: open · refresh · split-down ·
split-right · remove-split · ×. `Open ▾`'s label plus a menu-popping split
button ran ~160pt of a 24pt header, which is most of a tile in a 4x4 grid.
Icons cost ~90pt (~110pt with remove-split) and keep the pane's NAME readable,
which is what you navigate by. Refresh sits away from × deliberately: it ends
the running agent and must not neighbour close. `buildHeaderButton` configures
them all, because near-identical blocks are how buttons drift apart.
**Remove-split** (`collapseTileSlot`) is × and then × again in ONE press: it
detaches the pane and collapses its split through `TileProfile.close`. That is
the same thing `zetty tiles detach --collapse` does. It is built only when
`canRemove`, and it is never added to the header otherwise, because a hidden
button with no position leaves the chain of constraints ambiguous. That is safe
because tiles are rebuilt on every structural change, so `canRemove` cannot go
stale on a live tile. A filled tile's right-click menu offers **Remove Split**
too, beside **Detach Pane**.

**`Open ▾` left the status bar and arrives per tile.** `StatusBarView
.isTileMode` folds the pill away (and drops the `⋯` menu's "Open Directory In"
submenu with it) through `updateEditorVisibility()` — its own function beside
`updateBroadcastVisibility`/`updateAccountVisibility`, because two inputs decide
it and a renderer that also owned `isHidden` would fight `applyCompactState`.
Each `TileView` header carries a `folder` icon instead, hidden for a
`.missing` slot.

**The menu item carries its DIRECTORY, not just its app.** `editorMenuPicked`
used to call `focusedDirectoryURL()`, which reads `paneTree.focusedSurface` —
global focus. Wire a per-tile button to that and every one of them opens
whichever tile currently HAS focus, so clicking tile 7's button gives you tile
3's directory. `editorMenu(for:)` bakes the url into each item's
`EditorTarget`, and `focusedDirectoryURL()` is now just
`directoryURL(for:)` applied to the focused pane. Finder went through the same
item for the same reason; it no longer has an action of its own.

**Chrome.** The strip carries tile-view pills while the grid is up
(`refreshTabBar` branches; every `tabBar.on*` callback branches with it, and so
do ⌘1…⌘9 and ⌘{ / ⌘} through `selectTabByNumber` and `selectNext/PreviousTab`,
**The status bar's account · cwd · git left too, onto a footer per tile.**
`StatusBarView.updateLocationVisibility()` hides `accountPill`, `cwdLabel`,
`gitStack` and `locationChip` while `isTileMode`, and `refreshStatusBar` skips
the bar's account resolve and git probe entirely. **The footers ride the
coalesced chrome tick EXPLICITLY** (`setNeedsChromeRefresh`'s closure), not
`refreshStatusBar`: in tile mode `refreshTabBar` returns before it reaches the
status bar, and the first cut relied on it — footers then never saw a `cd`.
`registry.onTitleChange` (which fires for cwd changes too) marks the pane
dirty in `TileDirectoryCache`, and the tick refreshes only while something is
dirty. `TileStatusLineView` is the status bar per tile, which is
why it is MONO; don't "fix" it to `chromeFont`. Only a `.terminal` tile builds
one, so empty, missing, attaching and failed cells keep their full height.
Four rules keep it cheap:

- **It updates in place** (`TileGridView.updateStatusLines` →
  `TileView.setStatusLine`, which no-ops on an equal `TileStatusLine`), NEVER
  through `refreshTileGrid`, which rebuilds every tile. `applyTheme` clears the
  render cache, or the footer freezes in the old palette. `tileDescriptors`
  also carries the line, so a rebuild draws it at once rather than blank.
- **Git is probed per DIRECTORY** (`TileGitProber`), serially on `gitQueue`,
  re-probed by the existing 15s timer only while the grid is up, and reset
  when it closes; a result for a directory no tile shows is dropped. Sixteen
  tiles in one repo are one `git` process.
- **Parts drop whole** by `TileStatusLine.visibleParts(width:widths:)` — ↑↓,
  account label, ●n, account icon, branch — and the cwd truncates at its head.
  The branch is measured CAPPED (`branchWidth(labelWidth:)`, 120pt label) and
  truncates at its tail, or one long feature-branch name pushes the account
  and ●n out first. A tile too short for a footer plus a usable terminal
  (`fitsFooter`) zeroes the footer's height in `setFrameSize` rather than
  over-constrain header + footer + body.
  The cwd chain is `paneDirectory(for:)`, shared with the bar so the two
  cannot disagree. It reads a FILE (`PaneCwdStore`), so `TileDirectoryCache`
  re-reads only a dirty pane, at most once a second each (a spinning agent
  dirties its pane every frame), and schedules one retry so a `cd` followed by
  silence still lands. The tick takes ids from `grid.attachedSurfaceIDs`, not
  `tileResolution()`, which `realpath`s every project root.
- **The footer's account chip restyles only when the account moves**
  (`chipToken`), and it is an icon + label in a `ClickRowView`, not an
  `NSButton` — no `attributedTitle` to leak KVO, and no button insets to make
  the measured width lie. `hitTest` answers with the chip or the footer, never
  a label, so a single click focuses the tile; a double-click is swallowed,
  because on a tile it means "leave the grid" and that belongs to the header.

The bar's `scheduleGitProbe` guard compares against `statusBarSurface`, not
`paneTree.focusedSurfaceID`: in tile mode those differ, and the old guard
silently dropped every result. Leaving the grid clears
`lastGitProbeDirectory` so the bar re-probes rather than showing git as old as
the grid session.

whose menu titles `validateMenuItem` renames to "Tile View". Before that, ⌘N
selected the active project's tab BEHIND the grid and `focusedTerminalView()`
stole the keyboard from the focused tile. `selectTileViewIfDifferent` and
`cycleTileView` are shared with the prefix layer, and pressing the number of
the view already showing is a no-op, because `selectTileView` resets tile
focus), `+`
raises the profile library as a menu, and the tab bar keeps its sidebar and
grid buttons — hiding the whole bar took the sidebar toggle with it, which is
why only the pills fold. The running/idle count is a status-bar chip in the
LEFT cluster, never `pillStack`: it changes on the probe's 3s tick, and
anything in the trailing stack that changes width on a timer slides Broadcast
and `Open ▾` out from under the pointer. Tiles carry a 1pt border and a 12pt
gap, with the border going accent on focus so there is one accent cue, not two.

**`TileGridView` and `TileAttachPicker` are both in `probeWindowFloor()`'s
list.** They live inside the main window, so a floor either sets is invisible
to every other measurement — how the command palette shipped growing the window
on ⌘K. Every layout pass logs `tiles: count=… cols=… cap=… tile=…x…`; verify a
change here by reading that back, not by eye.

**Scripting the grid.** `zetty tiles` grew verbs beyond the toggle, and they
follow some rules that are easy to get wrong:

- **While the grid is up, the focused TILE is the focused pane.**
  `statusSnapshot` marks `isFocused` from `tileFocusedSurfaceID`, not from the
  active tab's tree. So the default `send`/`capture` target is what you are
  looking at, and not a pane hidden behind the grid. When no tile is focused
  (the chooser) it falls back to the ordinary rule. Naming nothing would send
  the default target to whichever pane happened to be listed first.
- **`focus --pane` never leaves the grid and never changes the active
  project.** `focusPaneInTiles` sets the pane as its TAB's focused pane (a tile
  shows its tab's focused pane, so this is what makes a split tab's tile show
  the right one), attaches the tab if the view lacks it, and focuses the tile.
  `split --focus` and `break --focus` go the same way. The ordinary
  `focusPane(at:)` would `revealProject`, which is exactly the move tile mode
  forbids.
- **Where it lands is `TilePlacement`, the one rule.** A tab already in the
  view stays in its slot, otherwise the first hole inside the layout is filled,
  otherwise the focused slot splits side by side and the new half takes it.
  Holes past `capacity` are not holes: an old library can carry more slots
  than leaves, and a hole out there is not on screen.
- **`tiles attach` / `detach` / `split` do not bring the grid up**, and
  `attach` does not move tile focus. They are background verbs, like every
  other CLI verb that reshapes the workspace. `attach` also leaves the tab's
  pane focus alone when that tab is on screen outside the grid, because
  moving it there would move the caret out from under the user.
- **Slot numbers are 1-based at the CLI and in `status`**, and only
  `capacity` slots are reported. That is what the grid draws, and what the
  numbers index.
- **`split`, `close` and `break` from the CLI re-resolve the grid**
  (`refreshTilesAfterWorkspaceEdit`) and must not call `makeFirstResponder`
  on `focusedTerminalView()` while the grid is up. That view is the ACTIVE
  TAB's pane, and it steals the keyboard from the focused tile.

**The tile manager** (`TileManagerView`, ⇧⌘J) is the one place a view can be
DELETED. Like Sessions it has two hosts, the bottom drawer (default) and
`TileManagerWindowController`, chosen by `zetty-tile-manager-view`, which its
mode button rewrites. It is a separate key from `zetty-sessions-view`, so
detaching one never moves the other. The two drawers share the strip above the
status bar, and `setTileManagerDrawer` and `setSessionsDrawer` each close the
other: each is capped at 45% of the container, so two would leave no terminal.
In the drawer, `applyTheme` must not touch `window`, because that window is
the main one. Closing a pill keeps the profile
on purpose, so before the manager existed the library only ever grew. The
window and `zetty tiles delete` both go through
`TerminalViewController.deleteTileProfile`. That closes the view if it is
open, and deleting a view that is not the active one must not switch the grid
to a different view. Rename is validated by `TileProfileFile.validatedName`
everywhere: the strip's inline rename, the Rename View sheet, the manager and
the CLI. Names are unique case-insensitively, because two views sharing a name
could not be told apart by `zetty tiles open`. The manager reloads from
`persistTileLibrary`, `selectTileView`, `closeTileView` and `setTileMode`. It
defers a reload while a name is being edited, since `reloadData` would destroy
the field under the caret. Its selection fills `bg3` through a custom row view.
The system selection is accent, which here would read as "the showing view".

Deferred: import/export or sharing profiles through `.zetty/project.json`;
per-profile theme or font; nested grids; drag-reordering slots within a view;
reordering the library from the manager.
