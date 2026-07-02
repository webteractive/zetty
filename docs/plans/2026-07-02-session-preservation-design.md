# Session Preservation — Design

**Date:** 2026-07-02 · **Status:** approved

## Goal

Terminal sessions (PTYs and everything running in them) survive quertty
quitting, crashing, or relaunching. Reopening the app reattaches every pane to
its still-running session with its screen state replayed.

## Approach

**zmx, one session per pane.** [zmx](https://zmx.sh) is attach/detach extracted
from tmux: a daemon owns the real PTY behind a Unix socket, and reattaching
replays terminal state via libghostty-vt (the same VT engine quertty renders
with). It is what Supacode uses.

Each pane spawns `zmx attach quertty-<uuid8>` instead of a bare shell, where
`<uuid8>` is derived from the surface's persistent UUID (already stored in
`workspace.json`) — so a relaunch reattaches each pane to its own session.

Rejected: **tmux backend** (fights to be the multiplexer — status bar, prefix
key, alternate-screen quirks) and **an in-house persistence daemon** (months of
work reimplementing zmx).

## Decisions

- **Lifecycle: quit survives, close kills.** App quit/crash leaves sessions
  running; relaunch reattaches. Explicitly closing a pane/tab/project kills its
  sessions (`zmx kill`, best-effort, via the existing `registry.prune` funnel,
  which app-quit never calls).
- **Config:** new reserved key `preserve-sessions = true|false`, **default
  false**. Also a toggle in Settings (⌘,) under a "Sessions" section that writes
  the config. Applies to **new panes only** — existing panes are not reattached
  mid-flight.
- **Missing zmx, toggle path:** toggling ON in Settings with zmx absent offers
  to install it — confirmation dialog → `brew install neurosnap/tap/zmx` runs in
  the background with an "Installing zmx…" indicator → toggle lands ON on
  success; reverts with the manual command on failure/no-Homebrew.
- **Missing zmx, config path:** `preserve-sessions = true` by hand without zmx
  → panes fall back to plain shells, a one-time alert shows the brew command,
  Settings shows "zmx not installed" inline.
- **Orphans:** relaunching with preservation off (or removed panes whose kill
  failed) can leave `quertty-*` zmx sessions running. Settings shows a
  "N orphaned sessions · Kill All" affordance built on `zmx list` / `zmx kill`.

## Components

| Piece | Layer | Responsibility |
|---|---|---|
| `SessionPersistence` (QuerttyCore) | pure | session name from UUID (`quertty-<uuid8>`), attach-command string, `zmx list` output parsing, orphan diffing against live surface IDs |
| `AppConfig.preserveSessions` (QuerttyCore) | pure | 5th reserved key; parse/render/default-file docs |
| `ZmxRunner` (app) | IO | locate zmx (PATH + `/opt/homebrew/bin`, `/usr/local/bin`), run `list`/`kill`, run `brew install` async |
| `SurfaceRegistry` (app) | glue | when enabled+available, merge `command = <zmx> attach <name>` into the per-surface config; on `prune`, kill removed surfaces' sessions |
| `SettingsWindowController` (app) | UI | Sessions section: toggle (+ install flow + inline status), orphan count + Kill All |
| `AppDelegate` (app) | glue | thread config → registry; one-time missing-zmx alert on launch |

## Data flow

spawn: `viewFactory(surface)` → preservation on? zmx found? → per-surface config
gains `command = zmx attach quertty-<uuid8>` → shell runs inside zmx.
close: `prune(keeping:)` computes removed IDs → `zmx kill` each (background).
relaunch: same UUIDs restored from `workspace.json` → same session names →
`zmx attach` replays state.

## Error handling

All zmx invocations are best-effort with timeouts; a failed kill just leaves an
orphan (visible in Settings). A failed install reverts the toggle. Missing
Homebrew degrades to guidance text. Config-only enablement never breaks panes.

## Testing

`QuerttyCore` unit tests for session naming, command building, list parsing,
and orphan diffing. Registry/Settings/installer glue verified by running the
app (GUI verification is user-checked in this environment).
