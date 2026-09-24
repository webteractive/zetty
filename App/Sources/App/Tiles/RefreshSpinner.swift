import AppKit
import ZettyGhostty

/// Spins a refresh button while its agent is restarting, and flashes the
/// outcome when it finishes.
///
/// One helper rather than the same animation written into both hosts: the
/// button lives in a pane's gutter AND in a tile header, and two copies of a
/// layer animation would drift the moment either was tweaked.
///
/// Accent while spinning because accent means ACTIVE, then a short semantic
/// flash — green for a restart that came back, red for one that timed out — so
/// the outcome lands on the control you pressed instead of only in a dialog.
@MainActor
enum RefreshSpinner {

    private static let key = "zetty.refresh.spin"

    static func start(on button: NSButton) {
        button.wantsLayer = true
        guard let layer = button.layer, layer.animation(forKey: key) == nil else { return }
        // Centre the anchor so it turns on the spot rather than swinging around
        // a corner. Safe to compute once: the button is a fixed 13pt square
        // pinned in a stack, so it does not move while the animation runs.
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: button.frame.midX, y: button.frame.midY)

        button.contentTintColor = ZTheme.current.accentColor
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2          // clockwise, the way the glyph points
        spin.duration = 0.9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        layer.add(spin, forKey: key)
    }

    /// Stops the spin and flashes the result. `success` nil just stops.
    static func stop(on button: NSButton, success: Bool? = nil) {
        button.layer?.removeAnimation(forKey: key)
        let theme = ZTheme.current
        guard let success else {
            button.contentTintColor = theme.fg3Color
            return
        }
        button.contentTintColor = success ? theme.greenColor : theme.redColor
        // Long enough to register, short enough not to read as a new state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            button.contentTintColor = ZTheme.current.fg3Color
        }
    }
}
