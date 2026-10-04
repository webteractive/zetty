---
paths:
    - "App/Sources/App/TabBarView.swift"
    - "App/Sources/App/StatusBarView.swift"
    - "App/Sources/App/SidebarView.swift"
    - "App/Sources/App/SidebarDrawer.swift"
    - "App/Sources/App/CommandPaletteView.swift"
    - "Sources/ZettyCore/StatusBar/**"
    - "Sources/ZettyCore/Support/CommandSearch.swift"
    - "Sources/ZettyCore/Support/FuzzyMatch.swift"
    - "Sources/ZettyCore/Model/SidebarMetrics.swift"
triggers:
    - "changing the tab bar, status bar, sidebar, or command palette"
    - "the window refuses to resize or its minimum size grows"
    - "adding an overlay or anything inside the main window"
---

# Chrome layout: tab strip, narrow windows, status bar, palette, sidebar drawer

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

## The tab strip must never reach the window

A `TabItemView` carries a **required** minimum width, and the strip's
`.fillEqually` distribution multiplies it by the tab count. While the stack was
pinned straight into the bar, the chain `sidebar → pills → +` was required all
the way out to the window edge, so AppKit clamped the window's minimum content
width to roughly **80pt per tab** — ~2900pt at 30 tabs, wider than any display.
The window then simply refused to resize, which is how it was reported.

The pills therefore live in a **clipping `NSScrollView`** (`tabScrollView`) and
size against the clip, not the window. The rule that makes it work, and the one
that is easy to undo by accident:

> **Nothing may constrain the clip's width to the strip inside it.** The clip is
> sized by the OUTER chain alone — bar edge to bar edge, minus a *fixed*
> `addButtonSlot`.

Every attempt to relate the two re-broke it, and both failure modes were
measured, not guessed:

- An **optional** hug (`clip.width == strip.width` @ 750) still reaches
  `fittingSize`, which is what AppKit derives the window's minimum from — the
  window then *grew* with the tab count, to 3023pt at 23 tabs. Lowering the
  priority far enough to stop that also stops it sizing the clip at all.
- A **required constant** refreshed in `layout()` freezes the floor at the
  current strip width, so the window refuses to shrink *at all* — the original
  bug, worse.

`+` is therefore **not in the constraint chain**: it is frame-positioned in
`layout()` at `clip.minX + min(stripWidth, clip.width) + 4`, a sibling drawn
over the clip. It slides left to meet the last tab while the tabs fit and lands
in the reserved slot once they overflow. `translatesAutoresizing…` is `true` on
it for exactly this reason.

The **strip's own** width is a required constraint set in the same pass
(`updateStripWidth`), and that one is safe precisely because it constrains the
scroll view's *document view* — a size a scroll view never propagates outward.
It clamps to `[count × minWidth, count × maxWidth]`, which is what keeps
`.fillEqually`'s per-pill bounds satisfiable, and yields the intended ordering:

> **fill the bar → shrink the pills → scroll.** In that order.

Skip it and the strip just takes its natural width — every pill at `maxWidth` —
so tabs stop spreading into an empty bar AND start scrolling far too early (six
tabs overflowed a bar that comfortably showed thirteen). Measured on a 1117pt
strip: 1–5 tabs at 200pt with `+` trailing them, 6–13 compressing 200 → 86,
14+ pinned at the 80pt floor and scrolling.

Also load-bearing: **only a real selection move may scroll the strip**
(`revealTab(at:)` behind `selectionMoved`). Agents retitle tabs several times a
second; scrolling on every refresh would make an overflowing bar impossible to
scroll by hand — the same trap `rebuildOutline()` avoids in the sidebar.

Verify a change here by measuring, not by eye: log `view.fittingSize.width`
alongside the clip/strip widths and `addButton.frame.minX` while adding tabs
(`zetty new-tab`). `fittingSize` must stay FLAT as the strip grows, and `+`
must sit at `lastPillEnd + 4` until the strip overflows.

Also load-bearing: `NSButton.attributedTitle` leaks an AppKit KVO dependency
quartet **per assignment**, so any per-refresh assignment must be guarded by a
cached token (`StatusBarView`'s pill renderers, `SidebarView.styleBellButton`).
That leak, not view churn, was the memory growth — views and constraints were
never leaking.

The `git` pill is probed on **cwd change plus a slow 15s timer**, not per
refresh; `refreshStatusBar` runs on every tick and used to spawn a `git`
subprocess each time.

Verify a change here empirically, not by eye: `sample <pid> 10` (main-thread
`CA::Transaction::flush` share) and `heap <pid> | grep NSKeyValueDependency`
twice ~10 min apart (must be flat, not merely small).

## Narrow windows: the status bar and the sidebar both have to give way

The window minimum is **320 × 320** (`AppDelegate.minimumContentSize`),
verified reached — see the probe below. Two clusters had to stop contributing
REQUIRED width before it was attainable. Both are the same lesson the tab strip
documents at length, and both are easy to undo by accident:

1. **The status bar's ambient stats.** `infoStack` (appearance · scheme · shell
   · libghostty · version) is frame-positioned inside `infoHost`, and **nothing
   ties `infoHost`'s width to the stack inside it** — it claims the leftover
   between the left cluster and the trailing pills via a priority-1 fill plus a
   999 "don't overlap". Only `pillStack` (broadcast · CLI · sessions · the chip)
   is pinned to the trailing edge and measured. Hiding the ambient views on
   resize is NOT a substitute and was tried: the window can never shrink far
   enough to trigger the hide, because the wide layout's own width is the floor.
2. **The sidebar's width is `.defaultLow`, and 999 is NOT low enough.**
   Required, it becomes a floor AppKit adds to the content's minimum — so
   revealing the sidebar in a small window *resized the window* instead of
   splitting it. Dropping it to 999 changed nothing measurable: a 283pt sidebar
   still blocked the window at 479. The tab strip's note says the same thing
   from the other side — even a 750 hug reaches the minimum. Only
   `.defaultLow` gets out of the way, and it is safe because nothing competes
   for this width: with room the constraint is simply satisfied (verified — a
   283pt sidebar stays 283 in a 799pt window), and without it the sidebar
   compresses to `SidebarView`'s required `>= 120` render floor while the
   terminal keeps the rest. That floor is deliberately far below
   `SidebarMetrics.minWidth`, which bounds a *drag*, not a layout — and
   `NSTableColumn.minWidth` had to come down with it (160 → 60), since a column
   minimum propagates out through the scroll view as sidebar width the window
   cannot reclaim.

   Measured, pinned, at the minimum: `reached=320 sidebar=124 -> OK`.

   **A required CEILING sits beside that low-priority equality**
   (`sidebarWidthCeiling`, same constant, `<=`), and the two are not one
   constraint wearing different hats: "no wider than the chosen width" is an
   invariant, "exactly that wide" only a preference, and a maximum can never
   become a window floor. Without it the equality was the only thing holding
   the sidebar, and a measuring pass could resolve the leftover width onto it
   instead of the container — observed as `sidebar=1235 container=274`, panes a
   sliver and a COLLAPSED sidebar still mostly on screen (it slides off by its
   REQUESTED width, not by however wide it actually got). `logGeometry` prints
   `SIDEBAR-OVERFLOW want=…` when the frame outruns the request, so the symptom
   names itself.

**Lowering compression resistance on a STACK does not lower it on the stack's
children**, and assuming otherwise left the measured floor at 477pt after the
first fix looked complete. A stack pins its arranged subviews at required
priority, so one resistant child holds the whole stack — and the window — open.
Every child of `leftStack` therefore sets it individually: `cwdLabel` and
`branchLabel` (both `.byTruncatingTail`/`Head` labels whose truncation never
got the chance to fire), the git counts, the mode chips, and `accountPill`
plus its button — that one worst of all, since its width follows an account
name nobody bounded.

**`fittingSize` is an upper bound on the floor, not the floor.** It honours
optional constraints at their own priority, so a label that will happily
truncate under pressure still reports its full width. Measured here: a status
bar whose `fittingSize` is **657** sits in a window that drags to **320**
without complaint, because everything above ~215 of that is low-priority and
breaks. Reading `fittingSize` alone will send you chasing a floor that does not
exist — the tab strip's note is about REQUIRED constraints, where the two do
coincide.

The honest measurement is a real resize, which is what
`TerminalViewController.probeWindowFloor()` does: ask for `contentMinSize`,
read back what AppKit allowed, and log `OK`/`BLOCKED`. It measures **five**
states, because they have different floors and each one was or could have been
a bug on its own:

1. the ordinary window, sidebar collapsed;
2. the sidebar **pinned** — "revealing the sidebar resizes the window" was real;
3. the **command palette** open — it shipped growing the window on ⌘K;
4. the **sidebar drawer** open;
5. the **file viewer** open.

**Every overlay must be in that list.** An overlay exists only while it is
open, so any floor it sets is invisible to all four other measurements — that
is precisely how the palette got through. Add a `probeOverlay(_:window:target:
open:isOpen:close:)` call when you add an overlay; it no-ops the open/close if
the thing is already showing.

The file viewer gets its own pass (`probeFileViewer`) because it loads and
highlights off-main, so its panel does not exist in the synchronous turn. It
opens a real file rather than a synthetic one, so the measurement covers the
header, the footer pill and the highlighter's output — and it logs `shown=`,
without which an overlay that silently failed to appear would report a
reassuring `OK`.

It is opt-in (`ZETTY_PROBE_FLOOR=1`, because it briefly resizes the window) and
restores the frame afterwards:

```sh
zetty quit
ZETTY_PROBE_FLOOR=1 /Applications/zetty.app/Contents/MacOS/zetty &
/usr/bin/log show --predicate 'subsystem == "co.webteractive.zetty"' \
  --last 2m --info --style compact | grep chrome
```

(`log` is shadowed by a shell alias on this machine — use the absolute path.)

Every launch also logs one `floors(launch)` line naming each widget's width
separately — sidebar, tab bar, status bar, panes, container, content. AppKit
reports only the total, and "the window won't resize" says nothing about the
cause; this turns that report into a lookup instead of a bisect.

`StatusBarView.layout()` picks compact vs wide through the pure
`StatusBarCompaction.isCompact(available:required:wasCompact:)`, whose 24pt
hysteresis band stops the whole right cluster flapping while the window is
dragged across the threshold. It caches the last non-zero `infoStack
.fittingSize.width`, because a hidden stack measures zero and a zero
requirement reads as "it fits" — which would bounce the bar straight back to
wide. Every decision logs one `ZettyLog.chrome` line carrying `available`,
`required` and `contentFitting`; **verify a change here by reading that back
while dragging, not by eye.**

The compact chip (pure model in `ZettyCore/StatusBar/StatusInfo.swift` —
`StatusInfoItem` · `StatusInfoValues`, unit-tested) shows the **colour scheme**
— accent dot, name, chevron, the same anatomy as the location pill — and opens
the rest as a menu. Two things about it are deliberate:

- **Nothing in `pillStack` may change width ON A TIMER.** An earlier version
  rotated through the stats every 4s; because the stack hugs its content, every
  change resized it and shifted Broadcast sideways, so a pill you
  were about to click moved out from under the pointer. That is what killed the
  rotation — the frequency, not the readout. A scheme name changes only when
  someone changes the scheme, and by then the account has folded
  away, so the ordinary compact bar has nothing else in the stack to shift.
  **The left chip varies in width freely**: the left cluster is anchored to the
  leading edge and the action pills to the trailing one, so nothing clickable
  sits to its right at all.
- **A pending update takes the chip over** as the accent `↑ Update` button. It
  happens once, and burying the only actionable item in a menu was the
  alternative.

Its text is an `NSTextField`, never a button's `attributedTitle` — that setter
leaks a KVO dependency record per assignment. The click comes from an
`NSClickGestureRecognizer` on the pill.

## Compact is two pills, and the exceptions are conditional

A narrow bar renders the location pill and the `⋯` pill, and nothing else —
the account pill folds away with the ambient stats. Everything that
remains follows one rule: **it appears only in the state where hiding it would
be wrong**, and folds otherwise.

- **Broadcast** folds when the scope is OFF and breaks back out, label and all,
  the moment it is armed. It is the only pill that glows, because while it is
  active every keystroke reaches N shells; "broadcasting, but you'd have to
  click to find out where" is the worst of both. `BroadcastScope.displayLabel`
  is the single source for that name, shared by the pill and the menu item it
  folds into.
- **Mode chips** (`PREFIX`/`COPY`/`ZOOM`) already worked this way — hidden
  unless armed — and must stay that way. When PREFIX is armed the NEXT
  keystroke is consumed; a state you discover by clicking is not a state
  indicator.
- **The CLI pill** was already conditional on being stale, and **a pending
  update** already takes the `⋯` chip over. Both are the same rule.
- **`Open ▾` is not on the bar at all.** It was a pill here, folding into the
  `⋯` menu when compact, and it opened the FOCUSED pane's directory — which in
  a split tab means guessing. It is a `folder` button in each pane's gutter
  now (`PaneActionWiring.onOpen`), second after refresh as in a tile's header,
  so a button always names its own pane. Do not bring the pill back.
- **The account always folds** into the location dropup. It is identity, not
  state, and the status bar is not its only surface — the tab pill carries an
  account dot too.
- **In tile mode the whole location cluster is hidden** (account · cwd · git,
  and the collapsed chip), not folded — each tile carries its own footer. See
  `tile-mode.md`; `updateLocationVisibility()` owns it.

Visibility for the two folding pills lives in `updateBroadcastVisibility()` and
`updateAccountVisibility()` rather than in their renderers, because both are
now decided by two inputs (content AND compactness) and a renderer that also
owned `isHidden` would fight `applyCompactState`.

The **left** cluster folds too, but for a different reason, and conflating the
two would get the threshold wrong. The ambient stats fold so the WINDOW can
shrink; the left cluster already compresses freely and contributes nothing to
the floor. The cwd and git fold so the information stays **readable** — at a
narrow width a truncated branch beside a truncated path is two fragments and no
information, where one pill naming the directory and the branch is still an
answer.

So `layoutLocationCluster()` measures what the cwd would be LEFT WITH if git
rendered in full, against `LocationChip.cwdFloor` (120pt, about a dozen mono-11
characters — enough for `…/some-project`). Measuring "does git fit" instead
would never fire: the cwd truncates silently, so the answer is always yes.
Hysteresis is shared with `StatusBarCompaction` so both halves settle at the
same pace.

What does NOT fold from the left is just the **mode chips**, and only while
they are armed — see the rule above. Pure model + tests in `ZettyCore/StatusBar/LocationChip.swift`; the
chip carries `<dir> ⎇ <branch> ●`, and the full path plus the counts live in the
dropup — the chip only has to answer "where am I, on what branch, is anything
uncommitted".

Because the chip carries the directory as well, leaving a repo needs no special
case: `LocationChip.label` simply drops the branch half. `updateGit` still
re-renders, which is what stops a stale branch name persisting across a `cd`.

## Command palette: fuzzy, and window-sized

Filtering is `CommandSearch.rank(query:labels:)` (pure, tested), not
`label.contains(query)`. A substring filter needs a command's exact wording
before you can search for it — `go zetty` matched nothing against
`Go to Project: zetty`. Two rules:

- **Whitespace splits the query into terms, and EVERY term must match** (AND,
  not OR). A second word that widened the results would read as the filter
  breaking. It also makes order irrelevant, so `zetty go` works as well as
  `go zetty`.
- **Ties break on the original index, never on the label.** The selection sits
  at row 0, so an unstable sort would change what Enter runs between identical
  keystrokes. An empty query returns every index in the authored order — before
  anything is typed the palette is a menu, and its grouping says more than a
  score would.

Scoring is the shared `FuzzyMatch` in `ZettyCore/Support/`, which
`FileTreeSearch` now delegates to as well. It was lifted out of that file rather
than reimplemented: two fuzzy matchers would drift, and the file tree's
behaviour is the one users already have a feel for.

**Size — an overlay can set a window minimum too, and it took two fixes.** The
panel's 560pt width, its 96pt top inset and `listHeight` are all `.defaultLow`
preferences capped against the view, so a narrow or short window shrinks them
instead of being overhung.

`.defaultLow` and not `.defaultHigh`: **750 is inside the band AppKit folds into
the window's minimum content size**, so with the preferred width at 750 the
window GREW on ⌘K. Same lesson as the sidebar (which needed it at 999, not 750)
and the tab strip. When something must yield to the window, 250 is the number.

That alone left it BLOCKED at 341, because priorities were only half of it:
`PaletteRowView.titleLabel` had a leading constraint, **no trailing bound and no
truncation**. A label with nothing to truncate *within* just overhangs, and rows
are pinned to the list width which is pinned to the panel — so an unbounded
command label ("Go to Project: <any name>") set the panel's width and through it
the window's. Title, shortcut, search field, overflow hint and empty label are
now all bounded on both sides and compressible, the title yielding before the
shortcut (250 vs 251).

`probeWindowFloor()` opens the palette and measures with it up, because an
overlay's floor is invisible to every other measurement — which is exactly how
this shipped.

## Sidebar drawer

`⌘B` cycles **pinned → hidden → drawer**. From hidden the sidebar floats over
the content behind a `SidebarScrimView` rather than pushing it aside; at a
narrow window there is nothing to push aside.

- **The live `SidebarView` is re-parented, never duplicated.** A second
  instance would rebuild its outline on every chrome refresh — the exact cost
  the coalescing design exists to avoid.
- `applySidebarLayout()` owns the difference: with the drawer open the content
  container pins to the view instead of following the sidebar's edge, or the
  slide-in would drag the terminal along with it. Opening therefore re-pins,
  resets the edge off-screen, forces a layout, and only then animates.
- `collapsedEdgeConstant` reads the width constraint actually in force rather
  than `sidebarWidth`, since a drawer clamped to `view.width - 60` would
  otherwise park with a sliver still on screen.
- The pin button floats in the scrim *outside* the drawer edge because the
  sidebar's own corners are already taken (search + add above, bell + settings
  below); an overlay in either would cover a control instead of adding one.
- Esc is a local key monitor live only while the drawer is open —
  `KeyBindingEngine` has nowhere to register a direct chord in `.normal` mode.
- Drawer state is transient; only `sidebarCollapsed` is persisted.


## Inline tab rename

Double-click a pill, right-click it → **Rename…**, or press prefix + `,` to open
`TabBarView.beginRename`. Tile mode uses the same field for view names.
**Never call `field.selectText(nil)` there.** On a field that is already editing,
`selectText` ENDS the edit before selecting. That posts
`controlTextDidEndEditing`, and `RenameTextField` treats that notification as a
blur and commits. So the field closed in the same call that opened it. The
pills looked dead to double-click from ba92d24 until 2026-09-26, when a log
showed begin, commit and a first responder of the window itself all within
85ms of one double-click. Select with `currentEditor()?.selectAll(nil)`, and arm
`onCommit` only after the field is up. The right-click Rename… opens the field
on the next run-loop turn, because opening it while the menu is still tracking
lets the menu's dismissal take the keyboard straight back.
