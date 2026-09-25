import AppKit
import ZettyGhostty

/// Marks a refresh button while its agent is restarting, and flashes the
/// outcome when it finishes.
///
/// One helper rather than the same styling written into both hosts: the
/// button lives in a pane's gutter AND in a tile header, and two copies would
/// drift the moment either was tweaked.
///
/// A static accent tint while in flight because accent means ACTIVE — no
/// rotation, which read as tacky and duplicated the Reloading cover already
/// over the pane — then a short semantic flash, green for a restart that came
/// back and red for one that timed out, so the outcome lands on the control
/// you pressed instead of only in a dialog.
@MainActor
enum RefreshSpinner {

    static func start(on button: NSButton) {
        button.contentTintColor = ZTheme.current.accentColor
    }

    /// Clears the in-flight tint and flashes the result. `success` nil just clears.
    static func stop(on button: NSButton, success: Bool? = nil) {
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
