import AppKit

/// The dormant "screen" shown in the content area when the active project is
/// hibernated. It reads status (name + frozen tab count) and offers a single
/// intentional **Wake** action — viewing a hibernated project never wakes it;
/// only pressing Wake (or the context menu / palette / CLI) does.
@MainActor
final class HibernationPlaceholderView: NSView {

    private let onWake: () -> Void

    init(projectName: String, tabCount: Int, onWake: @escaping () -> Void) {
        self.onWake = onWake
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = ZTheme.current.bg1Color.cgColor

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Hibernated")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 40, weight: .regular))
        icon.contentTintColor = ZTheme.current.fg3Color
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "\(projectName) is hibernated")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.textColor = ZTheme.current.fgColor
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let tabs = tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
        let subtitle = NSTextField(labelWithString:
            "Its sessions and processes were freed to save resources.\nLayout preserved · \(tabs) · fresh shells on wake.")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = ZTheme.current.fg3Color
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let wake = makeWakeButton()

        let stack = NSStackView(views: [icon, title, subtitle, wake])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            icon.widthAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// A primary action pill: bg2 surface, accent border + title, accent glow —
    /// the one focus/brand element on the dormant screen.
    private func makeWakeButton() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(wakeClicked))
        button.isBordered = false
        button.bezelStyle = .inline
        button.wantsLayer = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.attributedTitle = NSAttributedString(
            string: "Wake Project",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: ZTheme.current.accentColor,
            ]
        )
        button.layer?.backgroundColor = ZTheme.current.bg2Color.cgColor
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1
        button.layer?.borderColor = ZTheme.current.accentColor.cgColor
        button.layer?.shadowColor = ZTheme.current.accentColor.cgColor
        button.layer?.shadowOpacity = 0.35
        button.layer?.shadowRadius = 8
        button.layer?.shadowOffset = .zero
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        return button
    }

    @objc private func wakeClicked() { onWake() }
}
