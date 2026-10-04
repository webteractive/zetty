---
paths:
    - "App/Sources/ZettyGhostty/**"
    - "App/Sources/App/ProcessFootprint.swift"
    - "Sources/ZettyCore/Session/BackgroundPanePolicy.swift"
triggers:
    - "investigating a memory or leak report"
    - "adding a pane close path or changing when surfaces are freed"
    - "changing hibernation or registry prune"
---

# Surfaces, memory and session lifetime

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

## Memory profile: the floor is GPU, not the heap

Measured across 5 → 37 live panes (34 projects awake), footprint is
**~110 MB fixed + ~37 MB per LIVE pane**, and **86% of it is graphics**
(`IOSurface` + `IOAccelerator` — libghostty's per-surface Metal render target
and glyph atlas). 5 panes ≈ 293 MB; 37 panes ≈ 1486 MB. The Swift heap is a
rounding error by comparison (~3.3 MB/pane).

Consequences worth knowing before chasing a "memory leak" report:

- **A big number is usually just awake projects.** ~1 GB ≈ 24 awake projects.
  Confirm with `footprint -p <pid>` and count live panes before assuming a leak;
  a real leak shows up as a *monotonic* `heap` class count, not a large total.
- **Waking a project spawns its pane immediately** — it is not lazy, so `wake`
  costs a full pane's GPU allocation up front.
- **It all releases.** Re-hibernating returned `IOSurface` to exactly its prior
  155 MB / 15 regions, so hibernation is currently the ONLY lever on this floor.
- CPU is unaffected by pane count now: 37 live panes with agents running held
  at 3.5%, versus 98% for 11 panes before the coalescing fix.

## Session lifetime = model ownership (never registry teardown)

**`registry.prune` frees GPU surfaces. It does NOT end sessions.** These were
once the same event (`onSurfacesRemoved` was wired straight to
`onSurfacesClosed`) and that was wrong in both directions:

- A pane closed before it was ever viewed had **no pair to prune**, so
  `onSurfacesRemoved` never fired and its zmx session leaked forever — a rogue
  shell surviving until the next launch's reap. The CLI close path had a manual
  workaround (`onSurfacesClosed?([id])`, "prune misses never-spawned panes");
  the two GUI paths (⌘W and the per-pane ×) did not.
- Freeing a background project's surfaces to reclaim memory was impossible
  without killing its shells.

The guarantee is now **`reconcileSessions()`**: it kills every `zetty-*` session
no surface in `WorkspaceModel.sessionOwnerSurfaceIDs` owns (ALL projects,
hibernated included — so it can never kill a session a dormant pane still
refers to), and sweeps orphaned `<uuid>.cwd` files in the same pass. It is
idempotent and costs one `zmx list`, so it runs debounced from
`rebuildSurfaceNodeView` (every structural change funnels through there) plus a
300s backstop. `onSurfacesClosed` remains only as the *fast* path. Adding a new
close path therefore cannot leak a session — that was the point of moving it.

## Freeing background panes' pixels

`free-background-panes-after = <duration|off>` remains a reserved, parsed, and
rendered key, but automatic background-surface release is temporarily disabled.
Destroying a live preserved surface can block inside libghostty's synchronous
subprocess teardown (`ghostty_surface_free` → `pthread_join`); because AppKit
owns the surface and releases it on the main thread, that freezes the entire app.

Until teardown can be made non-blocking safely, `rebuildSurfaceNodeView` keeps
every live surface belonging to an awake project attached by pruning against
`allSurfaceIDs`.
Manual hibernation still frees a project's surfaces after ending its sessions
— and now strictly AFTER. `hibernateProject` marks the project dormant at once
(so the sidebar, CLI and `zetty status` agree immediately) but, with zmx, hands
a `HibernationTeardown.Plan` to `ZmxRunner.endSessions`: idle shells (probe
says `""`, no busy agent — a MISSING probe entry is not idle) get
`HibernationTeardown.exitInput` via `zmx send`, the rest wait up to
`gracePeriod`, then whatever is still listed is `killAndWait`ed. Until the
completion runs, the project's panes sit in `surfacesAwaitingTeardown`, which
`retainedSurfaceIDs` keeps — freeing a surface whose `zmx attach` client is
live is the main-thread block above. It used to fire `zmx kill` async and
prune in the same turn, i.e. race it. A wake during the window is queued in
`wakeAfterTeardown`: waking at once would reuse surfaces attached to dying
sessions. A shell exiting on its own does not close its pane — Zetty never
sets the surface's `onClose` — so the layout survives the `exit`.
The pure `BackgroundPanePolicy` and config parsing remain for a future safe
reintroduction; do not wire them back to `SurfaceRegistry.prune` without proving
that preserved `zmx attach` teardown cannot block the main thread.
