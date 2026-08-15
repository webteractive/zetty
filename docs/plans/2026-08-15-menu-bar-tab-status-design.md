# Menu Bar Tab Status Design

**Date:** 2026-08-15

## Goal

Show agent activity in the hidden-window status menu so a user can identify running and attention-needing tabs before restoring Zetty.

## Presentation

Status menu destinations mirror the sidebar's existing semantic status dots:

- green — running;
- yellow — needs attention;
- dim gray (`fg3`) — idle; and
- no dot — no detected agent status.

Each marked item prefixes its existing title with a compact colored `●` through an attributed menu-item title. This keeps the native active-project and active-tab checkmarks available in their own column and avoids the extra width of textual status labels.

A single-tab project's direct item shows that tab's status. A multi-tab project's parent item shows the strongest status across its tabs, matching the sidebar roll-up order of needs-attention, running, then idle. Each submenu item shows its individual tab status.

## Data flow

`TerminalViewController.menuBarSnapshot()` reads each tab's focused surface status from the existing `AgentDetector`. `MenuBarTabSnapshot` carries the optional `AgentStatus`, and `MenuBarProjectSnapshot` carries the existing severity roll-up. No new detector, polling loop, persistence, or `ZettyCore` model is introduced.

`AppDelegate` continues rebuilding the native menu in `menuNeedsUpdate`. While constructing each destination it applies the status-prefixed attributed title using `ZTheme` semantic colors. Because the menu is rebuilt whenever it opens, the display reflects the latest agent events without background menu mutation.

## Accessibility and fallback

The visible title remains the normal project or tab name with a decorative leading dot. Marked menu items expose a status-aware accessibility label and tooltip such as “Tab name, running,” so the meaning is not conveyed by color alone. Unknown or absent status leaves the title, accessibility label, and tooltip unchanged.

## Verification

- Add focused coverage for the status roll-up if it is extracted into independently testable logic; otherwise rely on the already-tested detector status model.
- Build the macOS app target to verify AppKit attributed-title and accessibility APIs.
- Do not invoke Shut Down during verification.

