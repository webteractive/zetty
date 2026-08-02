# Zetty — Feature Specs

Design specs for nine proposed features, ordered by recommended ship sequence.
Nothing here is implemented. Each spec states its own effort and risk; read
**S0** first, because three of the others depend on it.

Conventions every spec below assumes (from [`CLAUDE.md`](../CLAUDE.md)):

- Pure, testable logic lands in `Sources/ZettyCore/**` (no AppKit import);
  process IO and views land in `App/Sources/App/**`.
- A new file under `App/Sources/` requires `mise exec -- tuist generate`.
- A new config key **must** be added to `AppConfig`'s `switch` (around
  `Sources/ZettyCore/Config/AppConfig.swift:214`). Forget it and the key is
  forwarded to ghostty, fails its all-or-nothing validation, and silently drops
  the *entire* custom config including the per-surface `command` — which
  strands preserved sessions into plain shells.
- New keybindings are `BindingCommand` cases plus entries in
  `defaultPrefixTable` / `defaultCopyTable`.
- Machine-driven chrome updates go through `setNeedsChromeRefresh(tabBar:sidebar:)`,
  never `refreshTabBar()` / `refreshSidebar()` directly.
- No hardcoded colors — `ZTheme.current.<token>Color` only.
- Every feature is documented in `README.md` in the same change, and
  `CLAUDE.md` / `AGENTS.md` stay byte-identical.

---

## S0 — Read terminal text in-process (foundation)

**Not user-facing. Do this first; S1, S8, and two existing bugs depend on it.**

### The finding

`TerminalViewController.swift:1007` defines `captureLines`, the single source of
terminal text for copy mode and ⌘-click path detection. It works by locating the
`zmx` binary, spawning `zmx history <session>`, splitting the output, and taking
`suffix(rows)`. Consequences, all documented as known limitations today:

- **Requires `preserve-sessions`.** A plain-shell pane gets no ⌘-click
  underline and no word motions, silently.
- **Rows are approximate.** `history` + `suffix(rows)` doesn't account for
  wrapped lines, so the row believed to be under the cursor can drift.
- **It's a subprocess per call.** Fine at copy-mode speed, unusable for
  incremental search.
- Word motions without a session fall back to "coarse 8-column jumps."

libghostty exposes exactly the right API and we aren't using it:

```c
bool ghostty_surface_read_text(ghostty_surface_t, ghostty_selection_s, ghostty_text_s*);
void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);
```

A `ghostty_selection_s` is two `ghostty_point_s` with a `tag` of
`GHOSTTY_POINT_VIEWPORT` (visible rows only) or `GHOSTTY_POINT_SCREEN` (the
full screen *including scrollback*), and a `rectangle` flag for block vs.
linear flow. The returned `ghostty_text_s` carries the UTF-8 bytes plus
`tl_px_x` / `tl_px_y` — the pixel origin of the read region, which is what lets
a match be mapped back to a screen position for highlighting.

The reference implementation is already in the SPM package at
`Sources/GhosttyTerminal/InMemory/InMemoryTerminalSession.swift:75`
(`readViewportText()`) — it shows the full alloc/free lifecycle under a lock.

### Design

Add to `SurfaceRegistry` (App layer, since it touches the C surface):

```swift
/// Text from a live surface. `scrollback: true` reads the whole screen
/// including history; false reads the visible viewport only. nil when the
/// surface isn't live. Encapsulates the ghostty_text_s alloc/free pair.
func readText(for id: UUID, scrollback: Bool) -> String?
```

Then repoint `copyMode.captureLines` at it, keeping the `zmx history` path only
as a fallback for surfaces that aren't live (hibernated projects, never-viewed
panes) where the CLI's `capture` verb still needs to work.

### Why it's worth doing separately

It is a ~60-line change that deletes a subprocess from the hot path, removes the
`preserve-sessions` prerequisite from ⌘-click, makes row mapping exact, and is
the only reason S1 can be interactive. Landing it alone is a shippable
improvement with its own README note ("⌘-click now works without preserved
sessions").

### Testing

`readText` itself needs a live surface, so it isn't `ZettyCore`-testable — keep
the *consumers* pure and test those. The existing `CopyModeCursor` and
`FilePathToken` suites already cover the parsing; this only changes where the
string comes from. Verify manually: `preserve-sessions = false`, then ⌘-hover a
path in `ls -la` output — it should underline, which it does not today.

**Effort:** S · **Risk:** low · **Blocks:** S1, S8

---

## S1 — Scrollback search

### What the user gets

`Ctrl+B [` then `/` searches forward, `?` searches backward, `n` / `N` jump
between matches, `Esc` clears the query and keeps the cursor. Also bound to
`⌘F` as a native shortcut that enters copy mode and opens the search field in
one step, because that's what everyone will actually press.

Matches highlight as native Ghostty selections — the same mechanism
`CopyModeController` already uses to render the copy-mode cursor, so there's no
new drawing path. The current match is the selection; other matches are not
highlighted (see Open questions).

A search bar appears docked above the status bar showing the query, match
index, and count (`3/17`). It uses `ZTheme.monoFont` and `bg2` (elevated
input), per the surface ramp.

### Design

**Pure (`Sources/ZettyCore/Keybindings/CopySearch.swift`):**

```swift
public struct SearchMatch: Equatable { public let row: Int; public let column: Int; public let length: Int }

public enum CopySearch {
    /// All matches in `lines`, in reading order. `caseSensitive` follows
    /// smartcase: nil means "sensitive only if the query has an uppercase".
    public static func matches(query: String, in lines: [String],
                               caseSensitive: Bool?, regex: Bool) -> [SearchMatch]

    /// Index of the next match at or after `origin`, wrapping. nil if empty.
    public static func next(from origin: SearchMatch?, in matches: [SearchMatch],
                            forward: Bool, wrap: Bool) -> Int?
}
```

Smartcase and wrap-around are the two behaviors people notice immediately; both
are pure and cheap to test.

**Binding commands** — add to `BindingCommand`:
`copySearchForward`, `copySearchBackward`, `copySearchNext`, `copySearchPrevious`,
`copySearchCancel`. Defaults in `defaultCopyTable`: `/`, `?`, `n`, `N`, and
`Esc` handled by the existing cancel path once a query is active.

**App layer** — `CopyModeController` gains a search state (query, match list,
current index) and a `SearchBarView`. Text goes into the bar, so
`KeyInterceptor` must pass keys through while it's first responder; that
already happens via the existing "text-editing first responder" guard, but the
bar must be a real `NSTextField` for the guard to fire.

Jumping to a match reuses the existing cursor-move plumbing — set the cursor to
the match's row/column, then let the current synthesize-mouse-drag code render
the selection over the match length.

### Config

```
copy-bind = / copy-search-forward
copy-bind = ? copy-search-backward
```
Additive over the defaults like every other binding. No new reserved key
needed — `copy-bind` already exists.

Add one reserved key if we want regex opt-in: `search-regex = true|false`
(default false, literal substring). **Must** go in `AppConfig`'s switch.

### Edge cases

- **Search runs over the full scrollback**, which for a busy pane is large.
  Debounce incremental search ~80ms and cap the scanned region (last N lines,
  default generous) so typing stays responsive. This is only viable because of
  S0 — a `zmx history` subprocess per keystroke would be hopeless.
- **Wrapped lines** shift row math. S0 makes reads exact for the viewport, but
  a logical line wrapped across three rows still needs the match's row
  computed against the *rendered* rows, not the logical ones. Read with
  `GHOSTTY_POINT_SCREEN` and count rendered rows.
- **A mouse-capturing TUI** may swallow the synthetic clicks that render the
  selection — the same limitation copy mode already documents. Search still
  moves the cursor; only the highlight is lost.
- **The pane can scroll during search** if the program is still writing.
  Snapshot the text once when the query opens; don't re-read per keystroke.

### Testing

`CopySearchTests` in `Tests/ZettyCoreTests`: literal matches, overlapping
matches, smartcase on/off, wrap forward/backward, empty query, query longer
than any line, regex with an invalid pattern (must not throw into the UI).

**Effort:** M · **Risk:** low-medium (highlight fidelity) · **Depends on:** S0

---

## S2 — Pane resize in the prefix layer

### Scope correction

Pane resizing **already exists** and is fully wired: `PaneActions.resizePaneLeft/Right/Up/Down`
(`App/Sources/App/PaneActions.swift:54`) call
`Layout.nudgeRatio(closestTo:direction:by:)` in 0.05 steps, exposed as ⌥⌘
arrows in the View menu (`AppDelegate.swift:1521`) and as four command-palette
entries (`TerminalViewController.swift:1616`).

The only gap is the **prefix layer**: there is no `BindingCommand` case for
resize, so `Ctrl+B` + arrow does nothing. This is tmux parity trim, not a
feature.

### Design

Add four cases to `BindingCommand` — `resizeLeft`, `resizeRight`, `resizeUp`,
`resizeDown` — with `defaultPrefixTable` entries matching tmux's
`C-Left/Right/Up/Down`, and dispatch straight into the existing `PaneActions`
selectors. Nothing else changes.

Consider also `equalizeSplits`: libghostty exposes
`ghostty_surface_split_equalize`, and tmux's `select-layout even-*` is a common
reflex. That needs a `Layout.equalize()` in ZettyCore (recursively set every
ratio to 0.5) rather than the libghostty call, since Zetty owns the split tree,
not ghostty.

### Testing

`KeyBindingEngineTests`: the four chords resolve to the right commands and are
overridable by a user `bind` line. `LayoutTests` already covers `nudgeRatio`
clamping. Add `equalizeResetsEveryRatio` if equalize ships.

**Effort:** XS · **Risk:** none

---

## S3 — Shell integration (semantic prompts)

### The blocker, stated up front

**libghostty does not expose OSC 133 to embedders.** I grepped the vendored
header (`.../Build/Products/Debug/include/ghostty.h`): there is no prompt-mark
API, no jump-to-prompt binding action, and no semantic-region accessor.
`GHOSTTY_ACTION_PROMPT_TITLE` is unrelated — it's a request to show a
rename-title UI. The action enum has 50+ entries and none of them is a prompt
mark.

So the shape of this feature is decided by something outside the repo. Three
paths:

**(a) Upstream it.** Add prompt-mark events to libghostty's embedder API and
wait for a release. Correct, benefits every embedder, and entirely
schedule-dependent on someone else. This is the only path to a *good* version
of this feature.

**(b) Parse it ourselves from `zmx` output.** OSC 133 sequences pass through to
the pty; if zmx's history retains them, Zetty could parse marks out of captured
text. Requires `preserve-sessions`, inherits every row-drift caveat, and
duplicates terminal state Ghostty already tracks perfectly. A bad version of a
good feature.

**(c) Ship the useful subset that needs no marks** — see below.

### Recommendation: (c) now, (a) opportunistically

The single highest-value piece of shell integration doesn't need OSC 133 at
all: **notify me when a long command finishes.** Zetty already runs a
foreground-process probe every 3s (`ForegroundProcess`, feeding tab identity).
A transition from "some non-shell foreground process" back to "bare shell" in a
pane the user isn't looking at *is* command completion, at 3s granularity.

That reuses infrastructure wholesale: the notification fire site, the
`notify-sound` / `notify-badge` / `notify-system` gating, the per-project
tri-state overrides, and the click-to-focus-pane handler all exist for agent
needs-attention.

**Design:**

- New reserved key `notify-command-done = <duration|off>` (default `off`).
  When set, a foreground process that ran longer than the threshold and then
  exits, in a pane that is not the focused pane, fires the same notification
  path as an agent needing attention. **Add it to `AppConfig`'s switch.**
  Note the `notify-` prefix is already swallowed by
  `isReservedButUnsupported` for forward-compat, so an older build ignores it
  safely — that mechanism was built for exactly this.
- Per-project override alongside the existing notification tri-state in
  `ProjectSettings`.
- Pure logic in `ZettyCore/Agents/`: a small state machine over probe
  snapshots that emits `.commandFinished(paneID, command, duration)`.
  Testable without any process at all.

**Deliberately excluded** until (a) lands: jump-to-prompt, select-last-output,
exit-status marks in the gutter, command duration display. All of them need
real marks; approximating them from a 3s poll would be wrong often enough to
be worse than absent.

### Testing

Pure state machine tests: process appears then vanishes under threshold (no
fire), over threshold (fires), pane focused (no fire), pane focused *after* the
command started but before it ended (no fire), two panes finishing at once
(two events, badge count 2).

**Effort:** M for (c) · **Risk:** the good version is blocked upstream

---

## S4 — Workspace snapshot (reboot-durable)

### What the user gets

`zetty save [name]` writes the entire workspace — every project, its tabs, its
split tree with ratios, each pane's cwd, and each pane's foreground command —
to a timestamped JSON file. `zetty restore [name]` rebuilds it. A reboot kills
every zmx session; this is what survives that.

Also exposed as **Save Workspace Snapshot** / **Restore Snapshot…** in the
command palette.

### Why it isn't already covered

Two adjacent things exist and neither does this:

- **Layout templates** (`.zetty/project.json`) are per-project, capture cwds
  and startup commands, and are meant to be git-committed and shared.
- **`workspace.json`** persists live state across app quit, but is a single
  mutable file, not a named history, and its restore path assumes zmx sessions
  are still alive.

A snapshot is the third thing: whole-workspace, named, immutable, and explicitly
designed for the case where no session survives.

### Design

**Pure (`Sources/ZettyCore/Persistence/WorkspaceSnapshot.swift`):**

```swift
public struct WorkspaceSnapshot: Codable, Equatable {
    public let version: Int              // 1
    public let createdAt: Date           // caller-supplied; ZettyCore stays clock-free
    public let projects: [SnapshotProject]
}
public struct SnapshotPane: Codable, Equatable {
    public let cwd: String               // absolute
    public let command: String?          // probed foreground command, nil for a bare shell
}
```

Plus `WorkspaceSnapshot.capture(from:probe:)` and a `restorePlan(into:)` that
returns an ordered list of operations (`addProject`, `newTab`, `split(ratio:)`,
`send(command:)`) rather than performing them — so the whole rebuild is
testable without a UI.

**Storage:** `~/.zetty/snapshots/<name>.json`, `<name>` defaulting to an
ISO-8601 stamp. Keep the last N (default 10), prune oldest.

**Command relaunch is opt-in and whitelisted**, exactly as tmux-resurrect
learned to do it. A new reserved key:

```
snapshot-restore-commands = nvim, ssh, ~npm run dev
```

Bare name matches the command; `~` prefix restores the full argv. Everything
not listed comes back as a plain shell in the right directory. Blindly
re-running captured argv is how you accidentally re-trigger a deploy.

**Restore is additive**, like resurrect: a project whose rootPath already
exists is skipped, not duplicated. Restoring twice is a no-op.

### CLI

```
zetty save [name]                 → prints the snapshot path
zetty restore <name> [--dry-run]  → --dry-run prints the plan, changes nothing
zetty snapshots                   → list, newest first
```

`restore` is a **slow verb** — it copies nothing but it does spawn N panes and
inject commands, so route it like `clone`: plan on main, execute off the socket
queue, register results on main. `handleOnMain`'s default case deliberately
errors for slow verbs; add `restore` to that list or it will trip the
"internal: slow verb routed to the main handler" trap.

### Edge cases

- **Startup commands inject via `pendingStartupCommands`**, the same ~0.8s
  post-spawn `sendText` path templates use. That path is in-memory only by
  design so a relaunch never re-runs commands into preserved sessions — restore
  wants the opposite, so it must populate the pending map *before* each pane
  spawns, as `registerClone` does.
- **A snapshot references paths that may be gone.** Restore must skip a missing
  directory with a collected warning, not abort halfway leaving a half-built
  workspace.
- **Clones must not be snapshotted as ordinary projects.** A clone's rootPath
  is under `~/.zetty/clones/` and may have been deleted. Record `cloneSource`
  and skip clones on restore unless the source still exists.
- **Home is always present**, so restore must merge into the existing Home
  rather than creating a second one.

### Testing

`WorkspaceSnapshotTests`: round-trip a nested split tree with non-0.5 ratios;
restore plan ordering (parent tab before its splits); additive restore against
a workspace that already has one of the projects; whitelist matching including
the `~` full-argv form; a snapshot with a clone whose source is gone.

**Effort:** L · **Risk:** medium (the restore plan is fiddly; `--dry-run` is
the mitigation)

---

## S5 — Quick terminal

### What the user gets

A global hotkey (default `⌥Space`, configurable) drops a borderless terminal
panel from the top of the active display over whatever app is in front. Press
it again — or `Esc`, or click away — and it slides back. It is a scratch
terminal: rooted at home, plain shell, never persisted.

### Design

The content already exists — scratch terminals are project-less, ephemeral,
plain-shell panes in their own sidebar section. The quick terminal is a second
*presentation* of one, not a new kind of pane.

**App layer, new file `QuickTerminalController.swift`:**

- An `NSPanel` with `.nonactivatingPanel`, `level = .floating`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so it
  appears over fullscreen apps and follows spaces.
- Hosts a single `SurfaceNodeView` bound to one dedicated scratch surface,
  reused across toggles so the shell and its scrollback persist between
  invocations.
- Slide animation via `NSViewAnimation` on the panel frame, ~0.15s, honoring
  `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- Positioned on the display containing the mouse, full width, configurable
  height fraction.

**Global hotkey registration** is the only genuinely new capability. Use
`RegisterEventHotKey` from Carbon (still the supported path for a global hotkey
without accessibility permissions) rather than an `NSEvent` global monitor,
which would require Accessibility TCC approval — a permission Zetty currently
doesn't ask for and shouldn't start asking for over a convenience feature.

### Config

```
quick-terminal = <chord|off>     # default off; e.g. "alt+space"
quick-terminal-height = 0.4      # fraction of screen height
quick-terminal-screen = mouse|main
```

All three are reserved keys — **add them to `AppConfig`'s switch.** Parse the
chord with the existing `KeyChord` parser so the syntax matches `prefix` and
`bind`.

### Edge cases

- **The panel must never become the main window** in a way that confuses the
  rest of the app. `KeyInterceptor` guards on "events outside the main window"
  — verify that guard doesn't swallow keys destined for the quick terminal, or
  explicitly route them.
- **Its surface counts against the memory floor** (~37 MB of GPU per live
  pane). Since it's reused rather than recreated, that's one pane's worth,
  permanently, once first invoked. Consider releasing it after a configurable
  idle period using the existing `BackgroundPanePolicy` machinery — but note
  disqualifier #1: a pane with no preserved session is never released, because
  freeing a plain shell's surface kills the process. A quick terminal is a
  plain shell by design, so **it can't be freed without losing its state.**
  Either accept the permanent cost or make the quick terminal session-backed.
- **Hotkey conflicts** are invisible failures. `RegisterEventHotKey` returns an
  error when the combination is taken; surface that as a one-time alert rather
  than silently doing nothing.

### Testing

Chord parsing is pure and testable. The panel behavior is not — verify
manually, and note that screenshot-based verification is TCC-blocked in agent
sessions, so this one needs a human in the loop.

**Effort:** M · **Risk:** medium (global hotkey + panel focus are both fiddly)

---

## S6 — Remote projects over SSH

### Recommendation: don't build this

Specced because it was asked for, with the case against it stated plainly.

**What it would be:** a project whose rootPath is `user@host:/path`. Its panes
`ssh` in and attach to a remote multiplexer session. The sidebar, tab bar, and
CLI would treat it like any other project.

**Why it fights the architecture, concretely:**

- **`ForegroundProcess`** shells out to a local `ps -axo pid,pgid,stat,tty,command`
  to name tabs and pick logos. Over SSH that's a remote `ps` per probe, every
  3s, per host.
- **`GitStatusProbe`** runs local `git`; the status bar's branch pill would
  need a remote invocation on every cwd change plus the 15s timer.
- **Project clones** are `cp -Rc` — APFS copy-on-write on a local volume. There
  is no remote analogue; clones would have to be disabled per-project.
- **The file viewer** stats local candidate paths in `PathResolution` and reads
  bytes locally in `FileViewerLoader`. ⌘-click would need an SFTP fetch.
- **Env var injection** happens as ghostty `env` directives at surface
  creation; remote env would have to go through the ssh command line or a
  remote profile.
- **Session persistence** would depend on a remote `zmx` (or tmux) whose
  version and presence Zetty can't manage the way it manages the local binary
  download.

That's six subsystems each needing a local/remote branch, and every one of them
is a place where a network hiccup becomes a UI freeze. The honest comparison:
this is asking Zetty to become a terminal *and* an SSH session manager.

**The cheap 80%:** a project setting that makes new panes in that project open
with a startup command of `ssh host`. That's `ProjectSettings.startupCommand`,
which already exists, plus a documented recipe in the README. Users get remote
panes with local chrome semantics (tab names from the local `ssh` process, no
remote git pill), and nothing in the architecture branches.

**Effort:** XL · **Risk:** high · **Verdict:** ship the recipe, not the feature

---

## S7 — Undo close

### What the user gets

`⇧⌘T` reopens the most recently closed tab or pane, restoring its position in
the split tree and its working directory. Up to 10 deep. Also in the palette as
**Reopen Closed Tab**.

### Design

**Pure (`Sources/ZettyCore/Model/ClosedItemStack.swift`):**

```swift
public struct ClosedItem: Equatable {
    public enum Kind: Equatable { case tab(TabSnapshot); case pane(SurfaceNode, parentPath: [SplitBranch], ratio: Double) }
    public let projectRootPath: String
    public let kind: Kind
    public let index: Int          // tab index, for reinsertion
}

public struct ClosedItemStack {
    public init(capacity: Int = 10)
    public mutating func push(_ item: ClosedItem)
    public mutating func pop() -> ClosedItem?
    /// Drop everything belonging to a project that no longer exists.
    public mutating func prune(keeping rootPaths: Set<String>)
}
```

**Critical constraint:** closing a pane ends its zmx session — `onSurfacesClosed`
is the fast path and `reconcileSessions()` is the guarantee, killing any
`zetty-*` session no surface in `WorkspaceModel.sessionOwnerSurfaceIDs` owns.
So **reopen cannot resurrect the process.** It restores the *layout and cwd*
with a fresh shell. That must be stated in the README or it reads as a bug.

If we wanted true undo, the closed surface would have to stay in
`sessionOwnerSurfaceIDs` for the life of the stack — which means a "closed" pane
keeps a live shell burning until it ages out. That's a defensible option but it
inverts the current guarantee that closing frees resources, and it would make
`reconcileSessions` non-idempotent with respect to the stack. **Recommend the
fresh-shell version**; note the alternative and don't build it.

**Wiring:** push in `closePane(surfaceID:)` and the tab-close path, both in
`PaneActions` / `TerminalViewController`. Prune on project removal. Clear on
`scratch-clear` (scratch terminals are explicitly ephemeral; reopening one
contradicts the feature).

### Testing

`ClosedItemStackTests`: capacity eviction, pop order, prune by project, pane
reinsertion path correctness against a nested tree, tab index clamping when the
tab list shrank after the close.

**Effort:** S-M · **Risk:** low · **Note:** interacts with S4 (both serialize
split trees — share the codec)

---

## S8 — Cross-pane grep

### What the user gets

```
zetty grep <pattern> [--project <name>] [--ignore-case] [--context <n>] [--json]
```

Searches every pane's scrollback at once and prints `paneID · project/tab ·
line` hits. Finding which of thirty panes printed the stack trace is currently
a manual hunt.

Also surfaced in the command palette as **Search All Panes…**, whose results
focus the pane and jump to the line (reusing S1's match-jump).

### Design

Pure matching is **S1's `CopySearch.matches`** — same function, applied per
pane. The new work is orchestration:

- `ControlRequest.grep(pattern:project:ignoreCase:context:)`, a **slow verb**
  (it reads every live surface; on a 37-pane workspace that's real work). Route
  it like `capture`: plan on main, execute off the socket queue.
- Text comes from S0's `readText(for:scrollback:)` for live panes, falling back
  to `zmx history` for panes that aren't live but have a preserved session.
  Hibernated projects with no session are skipped with a note in the output —
  the same honesty `capture` already applies when it refuses to wake a project.
- Rendering lives in the pure `ControlCLI` alongside `statusLines`, so the
  output format is unit-testable.

### Edge cases

- **Never wake a project to grep it.** `capture` deliberately refuses rather
  than waking, because hibernating killed the session it reads. Grep inherits
  that: report `☾ project (hibernated, skipped)` rather than spawning shells.
- **Output volume.** A broad pattern across 37 panes can produce megabytes; the
  socket read caps at 1 MB per line (`ControlSocketServer.readLine`) but the
  *response* uses `writeAll` with no cap. Add a match limit (default 200) and
  say so in the output — silent truncation reads as "no more matches."

### Testing

`ControlCLIGrepTests`: output formatting with and without context lines, the
hibernated-skip marker, the truncation notice, zero matches, `--json` shape.

**Effort:** M · **Risk:** low · **Depends on:** S0, S1

---

## S9 — Per-pane titles

### What the user gets

Right-click a pane's gutter strip → **Rename Pane…**, or `Ctrl+B` `.` for an
inline edit. The name shows in the pane's gutter strip and in `zetty status`.
Tabs can already be renamed; panes cannot, so in a four-way split every pane is
anonymous.

### Design

Smallest spec here, and it slots into existing structures cleanly:

- `Surface.manualTitle: String?`, persisted in `workspace.json` next to the
  existing `lastTitle`. Decode tolerantly (`decodeIfPresent`) like `isHome` and
  `cloneSource`, so older files load.
- `TabTitle.display`'s precedence chain gains pane-level naming — but note the
  chain is about *tab* titles. A pane name should **not** feed the tab title
  unless the tab has exactly one pane; otherwise a four-way split has four
  competing names. Add `PaneTitle.display(manual:emitted:cwd:)` as a sibling
  pure function rather than overloading the tab one.
- Render in `SurfaceNodeView`'s gutter strip, `ZTheme.monoFont`, `fg3` when
  idle. The strip currently holds a focus dot and split/break/close targets —
  the name goes between the dot and the buttons, truncating with a tail ellipsis.
- `StatusSnapshot.Pane` gains `name: String?`, decoded with a default so a
  stale standalone `zetty` binary doesn't throw on a newer app's payload —
  the same hand-written `init(from:)` treatment `live` and `hibernated` got.
- Inline rename reuses the tab-rename editor (`Ctrl+B` `,`), so keep the two
  bindings adjacent: `,` tab, `.` pane.

### Edge cases

- **The gutter strip is chrome**, so its `update()` must no-op on unchanged
  input and any `attributedTitle` assignment needs a cached token — that KVO
  quartet leak is per-assignment and the strip redraws on every chrome refresh.
- **Renaming is user-driven**, so it calls `refreshSidebar()` directly rather
  than `setNeedsChromeRefresh` — input should feel immediate.

### Testing

`PaneTitleTests`: manual name wins over emitted, empty manual name clears back
to the fallback chain, truncation is a display concern (not tested in Core).
`StatusSnapshot` decode test with the `name` field absent.

**Effort:** S · **Risk:** low

---

## Summary

| # | Feature | Effort | Risk | Depends on |
|---|---------|--------|------|------------|
| S0 | Read terminal text in-process | S | low | — |
| S1 | Scrollback search | M | low-med | S0 |
| S2 | Resize in prefix layer | XS | none | — |
| S3 | Shell integration (subset) | M | blocked upstream for the good version | — |
| S4 | Workspace snapshot | L | medium | — |
| S5 | Quick terminal | M | medium | — |
| S6 | Remote projects | XL | high | **not recommended** |
| S7 | Undo close | S-M | low | shares codec with S4 |
| S8 | Cross-pane grep | M | low | S0, S1 |
| S9 | Per-pane titles | S | low | — |

**Suggested order:** S2 (an hour, pure parity) → S0 (unblocks two others and
fixes a documented wart) → S1 → S9 → S7 → S4 → S8 → S5 → S3(c). S6 stays
unbuilt; ship the README recipe instead.

## Open questions

1. **S1 highlight scope** — current match only, or all matches dimmed with the
   current one accented? All-matches needs N synthesized selections, and
   Ghostty renders one selection per surface. Probably current-only, but it's a
   real UX regression against `less`/`vim`.
2. **S3 upstream appetite** — is adding prompt marks to libghostty's embedder
   API something worth opening upstream, or is Zetty better off waiting for
   Ghostty to want it for itself?
3. **S4 vs. extensions** — if the extension host from the earlier discussion
   ever lands, snapshot/restore is the textbook first extension (pure
   `status --json` in, `new-tab`/`split`/`send` out). Building it in-core now
   means moving it later, or having both.
4. **S5 memory** — accept one permanently-live pane's ~37 MB, or make the quick
   terminal session-backed so `BackgroundPanePolicy` can free it?
