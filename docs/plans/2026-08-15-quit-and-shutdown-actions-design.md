# Quit and Shut Down Actions

## Goal

Give the two explicit App menu actions distinct, predictable meanings:

- **Quit Zetty** exits immediately while preserving any zmx-backed sessions.
- **Shut Down Zetty…** asks for confirmation, ends every Zetty session and service, then exits.

The main window's red close button keeps its existing confirmation behavior.

## Design

Replace the App menu's direct `NSApplication.terminate(_:)` Quit target with an
`AppDelegate` action. That action marks the termination as already authorized
and terminates immediately, so ⌘Q and **Quit Zetty** do not show the existing
quit alert.

Add **Shut Down Zetty…** immediately above **Quit Zetty** with no key equivalent.
Its `AppDelegate` action always presents a destructive confirmation explaining
that running processes and preserved sessions will end. Cancel leaves the app
untouched. Confirm starts the existing full-shutdown path off the main thread:
locate zmx, list every `zetty-*` session, wait for zmx to kill them, then request
application termination on the main thread. If zmx is absent or no sessions
exist, termination proceeds normally.

Extract the common termination behavior into one helper shared by the new GUI
actions and the control socket's existing `zetty quit --kill-sessions` handler.
This prevents the GUI and CLI shutdown meanings from drifting.

Normal application termination continues to save the workspace and stop the
control socket. Other in-process timers and watchers end with the process. Plain
shell panes end when their terminal surfaces are released; zmx-backed panes are
explicitly killed only by Shut Down.

## Compatibility

Keep the existing `confirm-quit` config key because it still controls the main
window close confirmation and removing an established unprefixed key risks it
being forwarded to Ghostty. Update its Settings and README wording so that
scope is clear. No persistence or control-protocol format changes are required.

## Verification

- Run the ZettyCore unit suite to ensure config and control protocol behavior
  remain intact.
- Run the app test target/build to verify the AppKit actions and menu compile.
- Manually verify that ⌘Q exits without prompting, the red close button retains
  its configured prompt, Shut Down has no shortcut and can be cancelled, and a
  confirmed Shut Down leaves no `zetty-*` zmx sessions.
