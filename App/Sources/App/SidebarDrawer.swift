import AppKit

// MARK: - SidebarScrimView

/// The dimming layer behind an open sidebar drawer. Clicking it closes the
/// drawer, which is the gesture people reach for before they look for a button.
///
/// It also does the less obvious half of the job: while the drawer floats over
/// the terminal, this view swallows every click that would otherwise land in a
/// pane behind it, so dismissing the drawer can never also move the cursor or
/// focus a different pane.
@MainActor
final class SidebarScrimView: NSView {

    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func applyTheme() {
        // Chrome depth is surfaces, not shadows (design rule 9): the scrim is
        // the darkest surface at partial opacity rather than a black wash, so
        // it reads the same way in a light scheme as in a dark one.
        layer?.backgroundColor = ZTheme.current.bg0Color.withAlphaComponent(0.55).cgColor
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    /// Claims clicks anywhere in its bounds even when a subview would decline
    /// them, so nothing leaks through to the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

// MARK: - SidebarPinButton

/// The "keep it open" affordance for a drawer, floated in the scrim just
/// outside the drawer's edge.
///
/// It sits outside rather than inside because the sidebar's own top and bottom
/// corners are already spoken for — search and add above, bell and settings
/// below — and an overlay in either would cover a control instead of adding
/// one.
@MainActor
enum SidebarPinButton {

    static func make(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = "Pin the sidebar open beside the terminal (⌘B closes it again)"
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.layer?.borderWidth = 1
        style(button)
        return button
    }

    static func style(_ button: NSButton) {
        let theme = ZTheme.current
        if let image = NSImage(systemSymbolName: "pin",
                               accessibilityDescription: "Pin sidebar")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)) {
            button.image = image
            button.contentTintColor = theme.fg2Color
        }
        button.layer?.backgroundColor = theme.bg2Color.cgColor
        button.layer?.borderColor = theme.borderColor.cgColor
    }

    /// Diameter of the round button, and the gap it keeps from the drawer edge.
    static let size: CGFloat = 22
    static let edgeGap: CGFloat = 10
}
