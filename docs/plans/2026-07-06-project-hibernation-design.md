# Project Hibernation — Design

**Date:** 2026-07-06 · **Status:** Approved

Free the resources of projects you're not working on. A project can be
**hibernated** — its terminal sessions, processes, and panes are torn down while
its layout is kept — and later **woken** to fresh shells. Hibernation can be
manual or automatic after a project sits idle.

## Decisions (settled with Glen)

| Question | Decision |
|---|---|
| What hibernate frees | **Stop everything** — kill the project's zmx sessions + all processes, tear down its panes. Layout kept; waking spawns fresh shells. Running work is lost. |
| Auto-hibernate trigger | **Idle + not busy** — after a configurable idle time AND no activity (no running foreground command / agent) in the project. |
| Persistence | **Stays hibernated** across quit/relaunch. |

## Model

- **`ProjectRuntime.isHibernated: Bool`** (app runtime state) and the persisted
  **`Project.isHibernated`** (workspace.json), round-tripped in `SessionSnapshot`
  both directions (mirroring `isPinned`).
- The layout (`tabList`: tabs/splits/cwds/titles) is untouched by hibernation —
  only the live surfaces/sessions are freed.

## Hibernate / wake mechanics

**Hibernate(P)** (never the active project — see below):
1. Collect P's surface ids (`tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }`).
2. Kill their zmx sessions via the existing `onSurfacesClosed(ids)` path.
3. Set `P.isHibernated = true`.
4. `rebuildSurfaceNodeView()` — its prune-union (`allSurfaceIDs`) now **excludes
   hibernated projects**, so the registry tears down P's ghostty surfaces (frees
   UI/GPU memory).
5. Persist (`onWorkspaceDidChange`) + refresh the sidebar.

**Wake(P):** clear `isHibernated`, make P active → rebuild re-creates its
surfaces and spawns **fresh shells** at each pane's cwd (new zmx sessions). Layout
is exactly as it was. Startup-template commands are **not** re-injected (matches
relaunch semantics).

**Never hibernate the active project.** Auto-hibernation skips it by definition.
Manual "Hibernate" on the active project first switches to the nearest
non-hibernated project (or is a no-op if it's the only one). On launch, hibernated
projects stay cold — excluded from the prune-union, so they never spawn until woken.

## Auto-hibernation

A pure decision in `ZettyCore` keeps this testable:

```swift
HibernationPolicy.shouldHibernate(
    idleFor: TimeInterval,       // now - lastActiveAt
    hibernateAfter: TimeInterval,// 0 = disabled
    isBusy: Bool,                // any running foreground cmd / agent in the project
    isActive: Bool,
    isHibernated: Bool,
    autoDisabled: Bool           // per-project opt-out
) -> Bool
```

Returns true only when `hibernateAfter > 0 && !isActive && !isHibernated &&
!autoDisabled && !isBusy && idleFor >= hibernateAfter`.

**App wiring:**
- Track per-project `lastActiveAt` (updated whenever a project becomes active).
- `isBusy` = any of P's panes has a non-empty foreground command
  (`foregroundBySurface`) **or** a running / needs-attention agent — so a project
  running a build or agent is never auto-hibernated even while unviewed.
- A ~60s timer evaluates every non-active project and hibernates those the policy
  selects.

## Configuration

- **`hibernate-after`** (AppConfig): a duration like `60m` / `2h` / `0` (default
  **`0` = off**). Parsed + unit-tested in `ZettyCore`.
- **Per-project opt-out** (`ProjectSettings.autoHibernate: Bool?`, tri-state via
  the Project Settings sheet): nil = follow global, false = never auto-hibernate
  this project. Manual hibernate always works regardless.

## UX

- **Sidebar:** hibernated projects render **dimmed** with a **moon (`moon.zzz`)**
  glyph instead of the diamond. Clicking a hibernated project **wakes** it.
- **Right-click project → Hibernate / Wake** (toggles by state).
- **Command palette:** "Hibernate Project" / "Wake Project".
- **Busy-confirm:** manual Hibernate of a project with running processes shows a
  confirm ("Still running: … — hibernating ends these"), reusing the
  `confirmClosingBusyPanes` pattern. Auto never hits this (it skips busy projects).

## Data flow

```
manual Hibernate / auto timer
  → (if active) switch to nearest non-hibernated project
  → kill P's sessions (onSurfacesClosed) + isHibernated=true
  → rebuild (allSurfaceIDs excludes hibernated → surfaces torn down) + persist + sidebar

select hibernated P (click) / Wake
  → isHibernated=false → activate → rebuild spawns fresh shells → persist
```

## Error handling / edge cases

- **Only one project, and it's hibernated:** disallow (can't hibernate the last
  active project) — hibernation always leaves at least the active project live.
- **Waking with a layout template present:** fresh shells only; no command
  re-injection (avoids duplicate side effects).
- **zmx not installed / preserve-sessions off:** hibernation still frees panes +
  processes (kills the foreground processes and tears down surfaces); there just
  are no zmx sessions to kill. Works either way.
- **Auto never surprises you:** the `isBusy` guard means a background build/agent
  keeps a project awake.

## Testing

- **`ZettyCore`:**
  - `HibernationPolicy.shouldHibernate` matrix (off when `hibernateAfter==0`,
    active, busy, opted-out, already-hibernated, not-yet-idle; on when idle+quiet).
  - `AppConfig` parses `hibernate-after` durations (`60m`, `2h`, `90`, `0`,
    invalid → 0).
  - `SessionSnapshot` round-trips `Project.isHibernated`.
  - `ProjectSettings` round-trips `autoHibernate`.
- **App layer** (not unit-tested): verified live — hibernate a project (sessions
  gone via `zmx list`, panes torn down, sidebar dimmed), wake it (fresh shells),
  auto-hibernate after a short `hibernate-after` on an idle/quiet project but not
  on a busy one, and hibernated state surviving relaunch.

## Non-goals (v1)

- Preserving running processes across hibernate (that's the opposite of the
  chosen "stop everything").
- Capturing/replaying scrollback on wake.
- Re-running startup commands on wake.
- A global "hibernate all idle now" command (could be a follow-up).
