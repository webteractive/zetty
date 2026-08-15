# Hide Dock Icon on Window Close Design

## Goal

When the main Zetty window's red close button is clicked, keep the app,
terminals, services, and sessions running behind the menu-bar status item while
removing Zetty from the Dock. Restore normal Dock and application-menu presence
when the main window returns.

## Activation lifecycle

The existing `windowShouldClose` handoff remains the single entry into menu-bar
mode. After ordering out the retained main window and installing the Z status
item, Zetty switches `NSApplication` from the regular activation policy to the
accessory policy. The existing asynchronous app hide then hides any remaining
Zetty windows without terminating their controllers or services.

The shared `showMainWindow` path performs the inverse transition. It restores
the regular activation policy before unhiding, activating, and bringing the main
window forward, then removes the status item. Every existing restore source—the
status-menu Show action, project/tab destinations, notification activation, and
application reopen—already uses this shared path.

Only the main window's red close button enters accessory mode. Ordinary ⌘H and
other visibility changes keep Zetty's regular activation policy.

## Failure behavior

Runtime activation-policy changes are best effort. If macOS refuses a switch,
the window/status-item handoff still completes, so the app remains recoverable;
the visible symptom is only a Dock icon that did not change as requested.

## Documentation and verification

Update the README's hidden-window description to state that the Dock icon hides
while the Z status item owns the workspace handoff. Verify with source/diff
checks and an AppKit build. Replace the installed application and restart it
through normal Quit so eligible sessions remain preserved. Do not invoke or test
Shut Down.
