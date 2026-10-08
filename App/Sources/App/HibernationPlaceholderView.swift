import AppKit
import ZettyCore

/// The dormant "screen" shown in the content area when the active project is
/// hibernated. It reads status (name + frozen tab count) and offers the
/// intentional wake — viewing a hibernated project never wakes it; only
/// waking it here (or the context menu / palette / CLI) does.
///
/// A project whose agents handed off lists what it can start with instead:
/// its handoffs, a fresh agent, a plain shell. That list is the SAME one the
/// new-tab and split chooser shows (`ChooserListView`, the same row titles
/// and the same bin), so a handoff or a session is picked the same way
/// wherever it is picked. The project comes back as a single pane; the
/// handoffs not picked wait for a new tab or split.
@MainActor
final class HibernationPlaceholderView: NSView {

    private let onWake: () -> Void
    private let onStart: (HandoffStart) -> Void
    private let onDelete: (HandoffRecord) -> Void
    /// What each row of the list starts the project with, parallel to it.
    private var starts: [HandoffStart] = []

    /// `onWake` is the plain wake of a project with no handoffs, its layout
    /// put back as it was. `onStart` is the pick, when it has some, and
    /// `onDelete` throws one of them away.
    init(projectName: String, tabCount: Int, handoffs: [HandoffRecord] = [],
         onWake: @escaping () -> Void, onStart: @escaping (HandoffStart) -> Void = { _ in },
         onDelete: @escaping (HandoffRecord) -> Void = { _ in }) {
        self.onWake = onWake
        self.onStart = onStart
        self.onDelete = onDelete
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

        // The newest few, as the chooser lists them; the rest are still
        // there the next time a pane is added.
        let listed = Array(handoffs.prefix(AgentChooserSheet.handoffRows))
        let tabs = tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
        var note = "Layout preserved · \(tabs) · fresh shells on wake."
        if !handoffs.isEmpty {
            note = (handoffs.count == 1 ? "1 handoff" : "\(handoffs.count) handoffs")
                + (handoffs.count > listed.count ? " (the newest \(listed.count) shown)" : "")
                + " · pick what to start with; the rest wait for a new tab or split."
        }
        let subtitle = NSTextField(labelWithString:
            "Its sessions and processes were freed to save resources.\n\(note)")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = ZTheme.current.fg3Color
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        // The handoff line is the longest thing here, and a label that will
        // not give is a window minimum.
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let action: NSView = handoffs.isEmpty ? makeWakeButton() : makeStartList(listed)
        let stack = NSStackView(views: [icon, title, subtitle, action])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(handoffs.isEmpty ? 20 : 16, after: subtitle)
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

    // MARK: - What to start with

    /// The chooser's width, as a preference: required, it would become the
    /// window's minimum.
    private static let listWidth: CGFloat = 320

    /// Handoffs first, then a fresh agent for each harness they came from
    /// ("fresh" has to be something), then a plain shell: the chooser's own
    /// order, rows and titles.
    private func makeStartList(_ handoffs: [HandoffRecord]) -> NSView {
        var items: [ChooserListView.Item] = []
        for handoff in handoffs {
            items.append(.init(title: AgentChooserSheet.handoffRowTitle(handoff.label),
                               icon: AgentIcons.icon(forTool: handoff.agent.rawValue)
                                   ?? NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil),
                               isDeletable: true))
            starts.append(.handoff(handoff))
        }
        let harnesses = handoffs.reduce(into: [AgentKind]()) { kinds, handoff in
            if !kinds.contains(handoff.agent) { kinds.append(handoff.agent) }
        }
        for kind in harnesses {
            // The chooser names an agent by its catalog name; so does this.
            items.append(.init(title: SpawnableAgent.byID(kind.rawValue)?.displayName ?? kind.displayName,
                               icon: AgentIcons.icon(forTool: kind.rawValue)
                                   ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)))
            starts.append(.fresh(kind))
        }
        items.append(.init(title: AgentChooserSheet.standardSessionTitle,
                           icon: AgentChooserSheet.standardSessionIcon))
        starts.append(.shell)

        // Clicked, not driven from the keyboard: the terminal's keys must
        // not reach a list whose Return or 1–9 would wake the project, so
        // no row stands pre-selected either.
        let list = ChooserListView(items: items, selectsFirstRow: false, truncatesLabels: true)
        list.translatesAutoresizingMaskIntoConstraints = false
        list.onActivate = { [weak self] index in
            guard let self, self.starts.indices.contains(index) else { return }
            self.onStart(self.starts[index])
        }
        // Deleting rebuilds the pane area, which removes this view: run it
        // once the click that is still inside it has returned.
        list.onDelete = { [weak self] index in
            guard let self, self.starts.indices.contains(index),
                  case .handoff(let handoff) = self.starts[index] else { return }
            DispatchQueue.main.async { [onDelete = self.onDelete] in onDelete(handoff) }
        }
        let width = list.widthAnchor.constraint(equalToConstant: Self.listWidth)
        width.priority = .defaultLow
        width.isActive = true
        return list
    }

    // MARK: - Waking a project with no handoffs

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
