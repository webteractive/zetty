# Pane Scroll-to-Bottom Action

## Goal

Expose the existing Scroll to Bottom command in every pane's top gutter, beside
the file-tree and split controls. The action must target the pane whose button
was clicked without moving keyboard focus.

## Design

Add an always-visible gutter button using the `arrow.down.to.line` SF Symbol
with a simple down-arrow fallback and the tooltip **Scroll to bottom**. Place it
immediately before the split-vertical and split-horizontal buttons so navigation
and layout actions remain grouped before the conditional break and close
controls.

Thread a surface-addressed `onScrollToBottom: (UUID) -> Void` callback through
`SurfaceNodeView`, `RatioSplitView`, and `LeafContainerView`, matching the
existing close, break, and split callback pattern. `LeafContainerView` remains
UI-only: its button and gutter context-menu item report the leaf's `surfaceID`,
while `TerminalViewController` owns the Ghostty operation.

Add a controller helper that resolves the `AppTerminalView` for a supplied
surface ID and performs Ghostty's native `scroll_to_bottom` binding action.
The existing View menu / ⌘↓ action delegates to the same helper with the
focused surface ID, keeping both entry points behaviorally identical. The
surface-addressed gutter path does not alter `paneTree.focusedSurfaceID` or the
window first responder.

Mirror the button as **Scroll to Bottom** in the gutter's right-click menu,
preserving the existing promise that the menu exposes the same pane actions.
Update README and DESIGN.md gutter anatomy accordingly.

## Error Handling

If the pane has no live registered terminal view, the command is a no-op. No
model, persistence, session, or control-protocol changes are needed.

## Verification

- Build the macOS app to verify the recursive callback plumbing and selectors.
- Run focused static checks for the empty/no-extra shortcut and menu wiring.
- Manually scroll two panes back, click the button on the unfocused pane, and
  confirm only that pane rejoins its live tail while keyboard focus stays put.
