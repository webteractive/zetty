# Background Surface Pruning Hang — Design

## Problem

Zetty 0.1.29 can become permanently unresponsive when
`free-background-panes-after` releases an idle project's live terminal surfaces.
A live process sample shows the AppKit main thread synchronously deallocating an
`AppTerminalView`, entering `ghostty_surface_free`, and waiting in
`pthread_join` while libghostty's I/O thread attempts to stop the preserved
`zmx attach` subprocess.

Because `SurfaceRegistry.prune(keeping:)` releases the terminal pair on the main
thread, an unbounded libghostty shutdown wait blocks the event loop and the
control socket. The timer invokes this path even when `hibernate-after` is off.

## Decision

Temporarily disable automatic background-surface pruning and restore the runtime
behavior from before 0.1.29:

- The hibernation timer evaluates only auto-hibernation.
- View rebuilds keep every live surface belonging to an awake project attached.
- Hibernated projects remain excluded and are still pruned after their sessions
  are explicitly ended.
- Explicit pane, tab, and project closure behavior is unchanged.
- `free-background-panes-after` remains a reserved, parsed, and rendered config
  key so existing configuration stays valid and is not forwarded to ghostty.
  It is documented as temporarily inactive.

This trades background GPU-memory reclamation for UI stability. Preserved
sessions, scrollback restoration, manual hibernation, and session reconciliation
continue to work.

## Rejected Alternatives

### Move pruning to a background queue

`AppTerminalView`, `TerminalSurfaceCoordinator`, and their controller graph are
AppKit/MainActor-owned. Releasing them off-main would replace a reproducible hang
with unsupported cross-actor UI teardown and potential crashes.

### Patch or time-bound libghostty shutdown in Zetty

The blocking join lives inside the prebuilt libghostty dependency. Fixing it
properly requires dependency-level ownership and subprocess-lifecycle changes;
Zetty cannot safely interrupt that join from the outside.

### Disable only the periodic timer call

Insufficient: `rebuildSurfaceNodeView()` also filters through
`attachedSurfaceIDs`, so a later project or layout switch could still prune an
eligible background surface and trigger the same hang.

## Implementation

1. Remove the app-layer `freeBackgroundPanesAfter` provider and automatic
   release helpers from `TerminalViewController`.
2. Remove the release call from `evaluateAutoHibernation()`.
3. Make both rebuild-time prune calls keep `allSurfaceIDs`, which contains every
   awake project's surface and excludes hibernated projects.
4. Update README and contributor documentation to mark the config option as
   temporarily disabled because libghostty teardown can block the main thread.
5. Preserve the pure configuration and policy code for compatibility and a
   future safe reintroduction.

## Verification

- Run the pure SwiftPM test suite.
- Run the app/Tuist tests.
- Build the macOS app.
- Confirm source-level regression guards: no timer path calls background release,
  and rebuild pruning uses `allSurfaceIDs` only.
- If a runtime smoke test is practical, launch with
  `free-background-panes-after = 5m` and confirm the app remains responsive after
  the configured interval.
