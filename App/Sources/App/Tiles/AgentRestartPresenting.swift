import AppKit

/// The chrome an agent restart drives on a pane, wherever that pane is hosted.
///
/// A pane appears in two unrelated views — `LeafContainerView` (the gutter) and
/// `TileView` (the grid) — and both must show the identical restart affordance.
/// They had three near-identical copies of these methods, which is precisely how
/// the tile half came to be missing the button while the gutter had it: two
/// implementations of one behaviour drift, and the drift is invisible until
/// someone works in the half that was forgotten.
///
/// Conformers supply only what genuinely differs — which button, which view the
/// cover goes over — and inherit the behaviour.
@MainActor
protocol AgentRestartPresenting: AnyObject {
    /// nil when this host has no button (a tile with no pane).
    var restartButton: NSButton? { get }
    /// The view the cover is parented ONTO. Must be the terminal view where one
    /// exists: libghostty's surface composites over anything merely beside it,
    /// so a cover added to the container is never seen.
    var restartCoverHost: NSView { get }
    var restartCover: ReloadingOverlay? { get set }
}

extension AgentRestartPresenting {

    func setRefreshVisible(_ visible: Bool) {
        guard let restartButton, restartButton.isHidden == visible else { return }
        restartButton.isHidden = !visible
    }

    /// Spins the glyph, then flashes the outcome.
    ///
    /// Forces the button visible while it spins: the foreground probe stops
    /// reporting the agent the instant it quits — which is mid-restart — so the
    /// ordinary visibility rule would hide the control halfway through its own
    /// animation.
    func setRefreshSpinning(_ spinning: Bool, success: Bool? = nil) {
        guard let restartButton else { return }
        if spinning {
            restartButton.isHidden = false
            RefreshSpinner.start(on: restartButton)
        } else {
            RefreshSpinner.stop(on: restartButton, success: success)
        }
    }

    /// Covers the terminal while its agent is quit and resumed. The surface is
    /// untouched — only hidden.
    func setReloading(_ reloading: Bool) {
        if reloading {
            guard restartCover == nil else { return }
            let overlay = ReloadingOverlay()
            overlay.cover(restartCoverHost)
            restartCover = overlay
        } else {
            restartCover?.dismiss()
            restartCover = nil
        }
    }
}
