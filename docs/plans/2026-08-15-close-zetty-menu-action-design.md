# Close Zetty Menu Action

## Goal

Make the main Zetty menu expose the same retained-window handoff as the red
window close button, using the standard macOS Hide shortcut.

## Design

Add **Close Zetty** with the key equivalent **⌘H** to the lifecycle section of
the Zetty application menu. Route the action through `NSWindow.performClose` so
the existing `windowShouldClose` path remains the single owner of hiding the
window, installing the status item, and switching to accessory activation.

Order the lifecycle actions exactly as:

1. **Close Zetty**
2. **Quit Zetty**
3. **Shutdown Zetty**

Quit retains **⌘Q** and preserves eligible sessions. Shutdown retains its
confirmation and full session-cleanup behavior. No terminal keybinding or
configuration format changes are needed.

## Verification

Run the app tests/build to catch AppKit menu and selector errors. Do not invoke
Close, Quit, or Shutdown during automated verification because the running Zetty
instance owns the active work session.
