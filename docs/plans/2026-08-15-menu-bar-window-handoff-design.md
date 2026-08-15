# Menu Bar Window Handoff Design

**Date:** 2026-08-15

## Goal

Closing Zetty's main window should move the running app into the macOS menu bar instead of terminating it. All terminal surfaces, services, and preserved or unpreserved sessions remain alive. The menu bar provides a compact way to return to any awake project or tab, while Quit and Shut Down retain their distinct lifecycle semantics.

## Window lifecycle

- Clicking the main window's red close button orders the retained window out instead of closing or terminating the application.
- Zetty stays running with its existing controller hierarchy, terminal surfaces, services, and sessions untouched.
- A status item is installed while the main window is hidden and removed whenever the window becomes visible again.
- `applicationShouldTerminateAfterLastWindowClosed` returns `false` as a defensive lifecycle guarantee.
- Dock reopening and other application activation paths restore the retained main window.
- A single AppDelegate-owned restore path selects an optional destination, activates Zetty, makes the window key and frontmost, and removes the status item.

This is deliberately a hide/show transition, not a second window lifecycle. Rebuilding the window or terminal controller would risk disconnecting active surfaces.

## Menu bar item

The status item uses a native template SF Symbol so it follows macOS menu bar appearance. It owns a native `NSMenu`, rebuilt whenever the menu opens so project and tab changes made through the control CLI while Zetty is hidden are reflected immediately.

The menu contains:

1. **Show Zetty**, which restores the current workspace without changing selection.
2. The awake workspace destinations:
   - Awake projects and Scratch are included.
   - Hibernated projects are omitted.
   - A project with one tab is a direct menu item.
   - A project with multiple tabs is a parent item whose submenu contains its tabs.
   - The active project and tab are indicated with native checkmarks.
3. **Quit Zetty**, which exits immediately while preserving eligible services and sessions.
4. **Shut Down Zetty…**, which uses the existing confirmation before stopping all services and sessions and exiting.

`Show Zetty`, Quit, and Shut Down remain available even if no awake project exists. Status-menu actions have no keyboard equivalents.

## Workspace selection

`TerminalViewController` exposes a read-only menu snapshot containing stable project/tab indices and already-resolved display titles. Title generation reuses the same rules as the tab bar rather than introducing status-menu-specific naming.

The controller also exposes one project-and-tab selection method. Existing sidebar selection and the status menu use that shared path so selection causes one coherent refresh, focus update, and active-project theme update instead of duplicated or nested selection work.

Choosing a destination first updates the workspace selection, then restores and focuses the retained window. A stale destination caused by a concurrent workspace change is ignored safely and falls back to showing the current workspace.

## Quit configuration cleanup

The old `confirm-quit` preference is obsolete because:

- the red close button no longer quits;
- Quit is intentionally immediate; and
- Shut Down owns the destructive confirmation.

Remove the property from `AppConfig`, its Settings toggle, serialization/default-config output, and user documentation. Add `confirm-quit` to `AppConfig.retiredReservedKeys` so old configuration files silently drop it instead of forwarding it to Ghostty as an unknown directive.

The old quit-confirmation state and termination prompt are removed. Explicit Quit continues through the established non-destructive termination path; Shut Down continues through its confirmed destructive path.

## Ownership

- `AppDelegate` owns the status item, dynamic menu, window hide/restore behavior, and application lifecycle actions.
- `TerminalViewController` owns menu snapshot construction and atomic project/tab selection because it already owns workspace presentation and focus.
- `ZettyCore` remains free of AppKit. Only configuration retirement needs pure-model coverage.

## Verification

- Add or update pure tests proving `confirm-quit` is treated as a retired unsupported key and is omitted from rendered Ghostty directives.
- Run the Swift package tests.
- Build the macOS app target.
- Do not launch, replace, hide, quit, or shut down the currently running Zetty instance during verification because it owns active user sessions, including this work session.

