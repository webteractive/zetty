import AppKit

/// Settings' Show QR Code…: the Tailscale sign-in page as a code to scan
/// with a phone, for a Mac reached over a screen share too slow to click
/// through a browser sign-in. An `NSAlert` sheet, the app's small-sheet
/// pattern (see `SpaceSheet`). It closes itself once the sign-in is done.
@MainActor
enum TailnetSignInSheet {
    private static var active: (alert: NSAlert, window: NSWindow)?

    static func present(over window: NSWindow, url: URL, modules: [[Bool]]) {
        dismiss()
        let alert = NSAlert()
        alert.messageText = "Scan to Sign In"
        alert.informativeText = "Scan with your phone's camera and approve the sign-in there. "
            + "Anyone who scans this can sign this Mac in to their own Tailscale account, so don't share it."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Open in Browser")
        let side: CGFloat = 240
        let imageView = NSImageView(image: QRCode.image(modules, side: side))
        imageView.frame = NSRect(x: 0, y: 0, width: side, height: side)
        imageView.imageScaling = .scaleNone
        imageView.setAccessibilityLabel("QR code of the Tailscale sign-in page")
        alert.accessoryView = imageView
        active = (alert, window)
        alert.beginSheetModal(for: window) { response in
            if active?.alert === alert { active = nil }
            if response == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    /// Closes the code once it's no longer wanted: signed in, or stopped.
    static func dismiss() {
        guard let (alert, window) = active else { return }
        active = nil
        window.endSheet(alert.window)
    }
}
