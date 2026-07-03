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

    // MARK: - Resize actions

    /// Keyboard pane resizing (⌥⌘ arrows): each press moves the divider of the
    /// nearest matching-orientation split of the focused pane by one step —
    /// left/right target a vertical split's divider, up/down a horizontal one.
    @objc func resizePaneLeft(_ sender: Any?)  { nudgeFocusedPane(direction: .vertical, delta: -Self.resizeStep) }
    @objc func resizePaneRight(_ sender: Any?) { nudgeFocusedPane(direction: .vertical, delta: Self.resizeStep) }
    @objc func resizePaneUp(_ sender: Any?)    { nudgeFocusedPane(direction: .horizontal, delta: -Self.resizeStep) }
    @objc func resizePaneDown(_ sender: Any?)  { nudgeFocusedPane(direction: .horizontal, delta: Self.resizeStep) }

    private static let resizeStep = 0.05

    private func nudgeFocusedPane(direction: SplitDirection, delta: Double) {
        guard let focusedID = paneTree.focusedSurfaceID,
              paneTree.layout.nudgeRatio(closestTo: focusedID, direction: direction, by: delta)
        else { return }
        rebuildAndFocus()
    }

    // MARK: - Focus actions (prefix-key layer)

    /// Move focus to the neighboring pane in a screen direction (prefix + h/j/k/l
    /// or arrows). No wrapping at the edges.
    func focusPane(_ direction: FocusDirection) {
        guard paneTree.focusNeighbor(direction) else { return }
        rebuildAndFocus()
    }

    /// Focus the next pane in tree order, wrapping (prefix + o).
    @objc func cyclePaneFocus(_ sender: Any?) {
        guard paneTree.cycleFocus() else { return }
        rebuildAndFocus()
    }

    /// Toggle zooming the focused pane to fill the tab (prefix + z). Zoom is
    /// transient — it never persists to `workspace.json`.
    @objc func zoomPane(_ sender: Any?) {
        guard paneTree.toggleZoom() else { return }
        rebuildAndFocus()
        refreshStatusBar()
    }

    // MARK: - Close action

    /// Close the focused pane.  If it is the only pane, this is a no-op.
    /// Asks first when something is still running in it.  Key equivalent: ⌘W.
    @objc func closePane(_ sender: Any?) {
        guard let focusedID = paneTree.focusedSurfaceID,
              paneTree.layout.surfaces.count > 1,
              confirmClosingBusyPanes([focusedID], what: "Pane") else { return }
        let closed = paneTree.closeFocused()
        guard closed else { return }
        rebuildAndFocus()
    }

    /// Close the pane identified by `surfaceID` (called by the per-pane × button).
    /// Asks first when something is still running in it; `confirmIfBusy: false`
    /// (the CLI path) skips the prompt.
    func closePane(surfaceID: UUID, confirmIfBusy: Bool = true) {
        guard paneTree.layout.surfaces.count > 1 else { return }
        if confirmIfBusy {
            guard confirmClosingBusyPanes([surfaceID], what: "Pane") else { return }
        }
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
