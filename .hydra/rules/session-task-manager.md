---
paths:
    - "Sources/ZettyCore/Monitor/**"
    - "App/Sources/App/SessionSampler.swift"
    - "App/Sources/App/SessionsView.swift"
    - "App/Sources/App/TaskManagerWindowController.swift"
    - "App/Sources/App/ProcessFootprint.swift"
triggers:
    - "changing the Sessions view or task manager"
    - "killing or interrupting sessions from the UI"
---

# Session task manager

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

**View → Sessions…** Design: `docs/superpowers/specs/2026-09-20-session-task-manager-design.md`.
Pure model in `ZettyCore/Monitor/` (`CPUTime` · `ProcessTable` · `CPURate` ·
`SessionLoad` · `TaskInventory` · `ByteFormat`), all unit-tested; process IO and
AppKit in `SessionSampler`, `ProcessFootprint` and
`TaskManagerWindowController`.

Four things here will look like tidy-ups and are not:

- **`ps %cpu` is deliberately unused.** It is an average over each process's
  whole lifetime, so an agent that pegged a core an hour ago and has idled
  since still reports high — for a tool whose job is naming the culprit that
  is confidently wrong. CPU is differenced from cumulative `time` instead,
  which is why the sampler is stateful and why **the first tick renders `—`
  rather than `0.0%`**: zero would be a claim, and a false one.
- **The sampler rides the foreground probe's existing `ps` sweep.** It does not
  own a timer. A second polling loop is the mistake the `git` pill and
  synchronous chrome refresh already made here. Its ingest takes its OWN hop to
  main, because the probe's hop returns early whenever foreground identities
  are unchanged — most ticks — and sampling from inside it would freeze the CPU
  column. Closing the window drops the retained snapshot, or reopening would
  difference against a snapshot from minutes ago and report one enormous rate.
- **Kill on an owned row closes the pane**, it does not kill the session.
  Killing the session directly leaves the pane attached to a corpse nothing
  respawns, and invents a second path for session lifetime when the rule is
  that lifetime follows model ownership with `reconcileSessions()` sweeping the
  rest. Orphans have no pane and are killed directly, unconfirmed.
- **Ownership is `sessionOwnerSurfaceIDs`, never `allSurfaceIDs`.** The former
  spans hibernated projects; the latter excludes them, so using it would report
  every dormant project's session as an orphan and invite the user to kill it.
- **`zmx list` is NOT a list of Zetty's panes**, and the task manager is the one
  place that forgot it. zmx is shared with other tools (Supacode, Tinker, a
  hand-rolled `zmx new`), so `SessionPersistence.sessionPIDs(fromList:)` filters
  on `namePrefix` exactly like its sibling `zettySessions(fromList:)` — which
  always did, and documents it. Without that filter a foreign session becomes a
  row nothing owns, i.e. an ORPHAN, and orphans are killed directly and
  UNCONFIRMED: two clicks in Zetty's task manager would have killed another
  tool's live session. Filtering belongs at the parse boundary rather than in
  `TaskInventory.rows`, or the sampler still burns CPU measurement on sessions
  that can never be shown.

**Docked or detached, one view.** `zetty-sessions-view = drawer | window`
(default `drawer`). `SessionsView` is the whole thing; the bottom drawer and
`TaskManagerWindowController` are both just hosts for it, because a second
implementation for the drawer would drift from the first within a release.

The drawer slots above `bottomGuide` in `rebuildSurfaceNodeView`, mirroring how
`CloneWarningBanner` slots below `topGuide`, so it appears and disappears with
the rebuild every structural change already funnels through. **Its height is a
`.defaultLow` preference capped at 45% of the container**, never a constant: a
required height there becomes a window minimum — the trap that has broken the
320pt floor three times — and a fixed 220pt drawer in a 320pt-tall window
leaves no terminal at all. It is in `probeWindowFloor`, the first overlay that
can actually move the floor since it lives inside the main window. The tile
manager's drawer (⇧⌘J) uses the same slot, so opening either one closes the
other. See `.hydra/rules/tile-mode.md`.

**The toggle IS the setting.** Detaching and docking rewrite
`zetty-sessions-view` through `AppConfig.rendered()`, so the form it is left in
survives a relaunch, and there is no runtime state that can disagree with the
file. An unrecognised value keeps the default rather than failing, because
ghostty validates all-or-nothing and a typo must not cost the whole config.

**`SessionsView` claims `sampler.onUpdate` in `setActive`,** not at
construction. That is what lets one sampler serve whichever host is on screen:
only the active view is subscribed, so a drawer and a detached window can never
both redraw from the same tick.

**The status-bar pill is a fixed-width glyph plus a dot**, never a percentage.
`pillStack` hugs its content, so a number changing every few seconds would slide
Broadcast out from under the pointer — the exact jitter that killed
the cycling ambient chip. The dot turns yellow above `SessionsView.busyThreshold`,
and the pill follows the compact rule the rest of the bar follows: it folds into
the `⋯` menu, except while a session is hot or the view is open.

**Interrupt is two mechanisms, and that is not redundancy.** A live pane gets
`ETX` written into its pty through `sendText` — literally Ctrl-C, respecting
the shell's job control, and it signals nothing so it cannot reach the wrong
process. Only a pane with no pty (never viewed, hibernated, or an orphan) falls
back to `SIGINT` on the foreground process group, and that path re-resolves the
session and its group from scratch first, because the pid on screen was sampled
up to three seconds ago and may have been reused.

**Numbers are labelled by what they are.** The header's footprint is measured
(`task_info` → `phys_footprint`, in-process, matching `footprint -p`). The
per-row column is headed **RAM** and measures the resident set of that
session's own processes — NOT what the pane costs Zetty — per-pane
GPU memory lives inside libghostty and is unreachable from Swift. There is no
per-pane memory column because there is no per-pane memory figure to put in it.

Known v1 limitations: an orphan's RUNNING column reads `shell`, because
`foregroundBySurface` is built by iterating `allSurfaceIDs` and nothing owns an
orphan; and with `preserve-sessions` off there are no sessions at all, so the
window shows the footprint and says so.

Writing tests against these types: **arithmetic inside an `#expect` operand is
typed as `Int` and compared against `Int64`**, which fails while printing two
identical numbers. Precompute the expected value into a typed constant.
