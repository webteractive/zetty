import AppKit
import ZettyCore
import ZettyGhostty

// MARK: - PaneActions

/// Thin action methods that mutate `PaneTree` then rebuild the view hierarchy.
///
/// Each action is an `@IBAction`-compatible `@objc` method so AppKit's
/// responder chain can route menu-item messages here without the menu needing a
/// direct outlet to the view controller.
extension TerminalViewController {

    // MARK: - Split actions

    /// Split the focused pane vertically (left / right).  Key equivalent: ⌘D.
    @objc func splitVertical(_ sender: Any?) {
        let workingDir = paneTree.focusedSurface?.workingDir ?? NSHomeDirectory()
        let newSurface = Surface(workingDir: workingDir)
        paneTree.splitFocused(direction: .vertical, newSurface: newSurface)
        rebuildAndFocus()
    }

    /// Split the focused pane horizontally (top / bottom).  Key equivalent: ⇧⌘D.
    @objc func splitHorizontal(_ sender: Any?) {
        let workingDir = paneTree.focusedSurface?.workingDir ?? NSHomeDirectory()
        let newSurface = Surface(workingDir: workingDir)
        paneTree.splitFocused(direction: .horizontal, newSurface: newSurface)
        rebuildAndFocus()
    }

    // MARK: - Close action

    /// Close the focused pane.  If it is the only pane, this is a no-op.
    /// Key equivalent: ⌘W.
    @objc func closePane(_ sender: Any?) {
        let closed = paneTree.closeFocused()
        guard closed else { return }  // last pane — nothing to do
        rebuildAndFocus()
    }

    /// Close the pane identified by `surfaceID` (called by the per-pane × button).
    func closePane(surfaceID: UUID) {
        paneTree.focus(surfaceID)
        let closed = paneTree.closeFocused()
        guard closed else { return }
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }

    // MARK: - Helpers

    /// Rebuild the split-view hierarchy, prune stale registry entries, and
    /// move first-responder to the newly focused terminal.
    internal func rebuildAndFocus() {
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }
}
