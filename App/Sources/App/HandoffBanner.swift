import AppKit
import ZettyGhostty

/// A full-width strip below the tab bar while the active project is on its
/// way to being hibernated, or after a handoff could not be written and it
/// was left awake. Same anatomy as `CloneWarningBanner`, and recreated on
/// every `rebuildSurfaceNodeView()` like it, so it reads `ZTheme.current` at
/// init.
///
/// A project is put away only once its agents have compacted. Until
/// then it is awake and looks it, so this is what says a hibernate is under
/// way and offers the way out; and a failure that left it awake would
/// otherwise look like a hibernate that did nothing.
@MainActor
final class HandoffBanner: NSView {

    enum State {
        /// Agents are compacting; the project is put away when they are done.
        case writing(agentPanes: Int)
        /// The pane that could not hand off, by its short id, and what
        /// stopped it, phrased to follow "Pane x: ".
        case failed(pane: String, reason: String)
    }

    static let height: CGFloat = 26

    private let onPrimary: () -> Void
    private let onDismiss: (() -> Void)?

    /// `onPrimary` is Cancel while writing and Hibernate Anyway after a
    /// failure; `onDismiss` is offered only after a failure.
    init(_ state: State, onPrimary: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.onPrimary = onPrimary
        self.onDismiss = onDismiss
        super.init(frame: .zero)

        let theme = ZTheme.current
        // In progress is not a warning: `fg3` is the idle tone. A failure is.
        let tone: NSColor
        let symbol: String
        let lead: String
        let detail: String
        let primaryTitle: String
        switch state {
        case .writing(let agentPanes):
            tone = theme.fg3Color
            symbol = "moon.zzz.fill"
            lead = "Hibernating. "
            detail = (agentPanes == 1 ? "Its agent is compacting its chat into a handoff"
                                       : "\(agentPanes) agents are compacting their chats into handoffs")
                + ", and the project is put away when that is done. Typing in it cancels."
            primaryTitle = "Cancel"
        case .failed(let pane, let reason):
            tone = theme.redColor
            symbol = "exclamationmark.triangle.fill"
            lead = "Handoff failed. "
            detail = "Pane \(pane): \(reason). This project was left awake."
            primaryTitle = "Hibernate Anyway"
        }

        wantsLayer = true
        layer?.backgroundColor = theme.bg2Color.cgColor

        let accentBar = NSView()
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = tone.cgColor
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)

        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = theme.borderColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: lead)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        icon.contentTintColor = tone
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let message = NSMutableAttributedString(
            string: lead,
            attributes: [.font: ZTheme.chromeFont(size: 12, weight: .semibold),
                         .foregroundColor: theme.fgColor])
        message.append(NSAttributedString(
            string: detail,
            attributes: [.font: ZTheme.chromeFont(size: 12), .foregroundColor: theme.fg2Color]))
        let label = NSTextField(labelWithAttributedString: message)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = lead + detail
        // The label gives way first, so the strip never holds the window open.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var arranged: [NSView] = [icon, label, button(primaryTitle, #selector(primaryPressed))]
        if onDismiss != nil { arranged.append(button("Dismiss", #selector(dismissPressed))) }

        let stack = NSStackView(views: arranged)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.setCustomSpacing(12, after: label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 2),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: ZTheme.chromeFont(size: 12),
                         .foregroundColor: ZTheme.current.accentColor])
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    // Either action rebuilds the pane area, which removes this view: run
    // them once the click that is still inside it has returned.
    @objc private func primaryPressed() {
        DispatchQueue.main.async { [onPrimary] in onPrimary() }
    }

    @objc private func dismissPressed() {
        DispatchQueue.main.async { [onDismiss] in onDismiss?() }
    }
}
