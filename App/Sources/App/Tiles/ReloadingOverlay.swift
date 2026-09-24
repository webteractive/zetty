import AppKit
import ZettyGhostty

/// Covers a pane while its agent is being quit and resumed.
///
/// Deliberately the same language as a tile's `.attaching` state — bg1, a
/// centred chrome-font line, a spinner — because it IS the same situation from
/// the user's side: the pane is there, something is coming back into it, and
/// the terminal underneath is mid-change and not worth watching.
///
/// It HIDES the pane; it never frees the surface. Tearing a live preserved
/// surface down is `ghostty_surface_free`, which is what disabled
/// `free-background-panes-after` — the restart drives the session through
/// `zmx send` instead, so nothing is detached and nothing can block.
@MainActor
final class ReloadingOverlay: NSView {

    private let label = NSTextField(labelWithString: "Reloading session…")
    private let spinner = NSProgressIndicator()

    init(message: String = "Reloading session…") {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        label.stringValue = message
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        spinner.startAnimation(nil)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 10),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func applyTheme() {
        let theme = ZTheme.current
        // Opaque, not translucent: a half-visible dead TUI underneath reads as
        // a rendering fault rather than as a pane that is busy.
        layer?.backgroundColor = theme.bg1Color.cgColor
        label.font = ZTheme.chromeFont(size: 11)
        label.textColor = theme.fg3Color
    }

    /// Pins into `host`, covering it entirely.
    func cover(_ host: NSView) {
        removeFromSuperview()
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    func dismiss() {
        spinner.stopAnimation(nil)
        removeFromSuperview()
    }
}
