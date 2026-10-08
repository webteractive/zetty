import AppKit
import ZettyGhostty

/// A keyboard-navigable modal sheet shown before a new tab/pane spawns in a
/// project with agents enabled: pick an agent to launch, a standard session,
/// manage agents, or cancel. Themed with `ZTheme`.
///
/// Keyboard: ↑/↓ move the selection, ⏎/Space launch it, Esc cancels, and 1–9
/// jump straight to that agent. Mouse clicks work too.
@MainActor
final class AgentChooserSheet: NSObject {

    enum Outcome {
        /// Launch this command, on this account (nil = whatever the project
        /// default resolves to).
        case agent(command: String, accountID: String?)
        /// Start this waiting handoff in the new pane.
        case handoff(UUID)
        /// Throw this waiting handoff away. Nothing is created; the caller
        /// asks again with what is left.
        case deleteHandoff(UUID)
        case standard(accountID: String?)   // plain session
        case manage                         // open Project Settings → Agents
        case cancel                         // do nothing
    }

    /// A handoff waiting in the project, offered ahead of the agents: it is
    /// work already under way.
    struct Handoff {
        let id: UUID
        let title: String
        /// The harness it resumes in, for its logo.
        let agentID: String
    }

    /// The most handoffs listed, here and on a hibernated project's screen.
    /// The newest come first, and the rest are still there next time.
    static let handoffRows = 5

    /// How a waiting handoff reads in a list, wherever it is picked.
    static func handoffRowTitle(_ label: String) -> String { "Resume: \(label)" }

    /// The row for a plain shell, wherever one is picked.
    static let standardSessionTitle = "Standard session"
    static var standardSessionIcon: NSImage? {
        NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
    }

    /// Beyond this many rows the per-account expansion is dropped: the sheet has
    /// no scroll view, and the 1–9 shortcuts only reach the first nine rows.
    private static let rowBudget = 12

    /// Keeps the sheet alive for the duration of the modal.
    private static var active: AgentChooserSheet?

    private let panel: NSWindow
    private let hostWindow: NSWindow
    /// Parallel to the list's rows: what each one does when activated.
    private let outcomes: [Outcome]
    private let completion: (Outcome) -> Void
    private let listView: ChooserListView
    private let offersHandoffs: Bool
    private let offersAgents: Bool

    static func present(
        agents: [ResolvedSpawnAgent],
        handoffs: [Handoff] = [],
        accounts: [AgentAccount] = [],
        defaultAccountID: String? = nil,
        limitSummary: @escaping (String) -> String? = { _ in nil },
        on window: NSWindow,
        completion: @escaping (Outcome) -> Void
    ) {
        let sheet = AgentChooserSheet(agents: agents, handoffs: Array(handoffs.prefix(handoffRows)),
                                      accounts: accounts,
                                      defaultAccountID: defaultAccountID,
                                      limitSummary: limitSummary,
                                      host: window, completion: completion)
        active = sheet
        window.beginSheet(sheet.panel)
    }

    private init(
        agents: [ResolvedSpawnAgent],
        handoffs: [Handoff],
        accounts: [AgentAccount],
        defaultAccountID: String?,
        limitSummary: (String) -> String?,
        host: NSWindow,
        completion: @escaping (Outcome) -> Void
    ) {
        self.hostWindow = host
        self.completion = completion
        self.offersHandoffs = !handoffs.isEmpty
        self.offersAgents = !agents.isEmpty

        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 10),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.appearance = ZTheme.current.appearance
        panel.backgroundColor = ZTheme.current.bg1Color
        panel.titlebarAppearsTransparent = true
        panel.title = ""

        // Rows: each agent (with its logo) — expanded into one row per account
        // when it can host them — then "Standard session" (terminal).
        //
        // The expansion is all-or-nothing: if expanding every account-capable
        // agent would overflow the sheet, none of them expand and the panes fall
        // back to the project's default account. A half-expanded list would be
        // worse than an unexpanded one, since the missing accounts would look
        // unavailable rather than merely unlisted.
        let expandable = agents.filter { resolved in
            resolved.agent.configDirEnvVar != nil
                && accounts.contains { $0.agentID == resolved.agent.id }
        }
        let expandedCount = expandable.reduce(0) { total, resolved in
            total + accounts.filter { $0.agentID == resolved.agent.id }.count   // + Default below
        } + expandable.count
        let expand = !expandable.isEmpty
            && handoffs.count + (agents.count - expandable.count) + expandedCount + 1 <= Self.rowBudget

        var items: [ChooserListView.Item] = []
        var outcomes: [Outcome] = []
        for handoff in handoffs {
            items.append(.init(title: Self.handoffRowTitle(handoff.title),
                               icon: AgentIcons.icon(forTool: handoff.agentID)
                                   ?? NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil),
                               isDeletable: true))
            outcomes.append(.handoff(handoff.id))
        }
        for resolved in agents {
            let icon = AgentIcons.icon(forTool: resolved.agent.id)
                ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            let hosts = expand ? accounts.filter { $0.agentID == resolved.agent.id } : []
            guard !hosts.isEmpty else {
                items.append(.init(title: resolved.agent.displayName, icon: icon))
                outcomes.append(.agent(command: resolved.command, accountID: nil))
                continue
            }
            // Limits come from Claude's reports, so only its Default row —
            // the default login of another harness has none to show.
            let defaultLimits = resolved.agent.id == AgentKind.claude.rawValue
                ? limitSummary(AgentAccountSupport.defaultID) : nil
            items.append(.init(title: Self.rowTitle("\(resolved.agent.displayName) — Default",
                                                    limits: defaultLimits), icon: icon))
            outcomes.append(.agent(command: resolved.command,
                                   accountID: AgentAccountSupport.defaultID))
            for account in hosts {
                items.append(.init(title: Self.rowTitle("\(resolved.agent.displayName) — \(account.name)",
                                                        limits: limitSummary(account.id)),
                                   icon: icon,
                                   dot: ZTheme.projectColor(id: account.colorID)))
                outcomes.append(.agent(command: resolved.command, accountID: account.id))
            }
        }
        items.append(ChooserListView.Item(title: Self.standardSessionTitle, icon: Self.standardSessionIcon))
        outcomes.append(.standard(accountID: defaultAccountID))
        self.outcomes = outcomes
        listView = ChooserListView(items: items)

        super.init()
        buildLayout()
        listView.onActivate = { [weak self] index in self?.activate(index) }
        listView.onDelete = { [weak self] index in
            guard let self, self.outcomes.indices.contains(index),
                  case .handoff(let id) = self.outcomes[index] else { return }
            self.finish(.deleteHandoff(id))
        }
        let fit = panel.contentView?.fittingSize ?? .zero
        panel.setContentSize(fit == .zero ? NSSize(width: 320, height: 200) : fit)
        panel.initialFirstResponder = listView
    }

    /// A row's name with its account's rate limits after it, when it has any.
    private static func rowTitle(_ name: String, limits: String?) -> String {
        limits.map { "\(name)  ·  \($0)" } ?? name
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: offersHandoffs ? "Start with a handoff?" : "Launch an agent?")
        title.font = ZTheme.chromeFont(size: 13)
        title.textColor = ZTheme.current.accentColor

        // What is on offer decides what is said: handoffs wait in a project
        // whether or not it has agents enabled.
        let explanation: String
        switch (offersHandoffs, offersAgents) {
        case (true, true):
            explanation = "This project has handoffs waiting from when it was hibernated. Resume one "
                + "here, launch an agent, or continue with a standard session."
        case (true, false):
            explanation = "This project has handoffs waiting from when it was hibernated. Resume one "
                + "here, or continue with a standard session."
        default:
            explanation = "This project has agents enabled. Pick one to launch here, or continue "
                + "with a standard session."
        }
        let helper = NSTextField(wrappingLabelWithString: explanation)
        helper.font = .systemFont(ofSize: 11)
        helper.textColor = ZTheme.current.fg3Color
        helper.translatesAutoresizingMaskIntoConstraints = false
        helper.widthAnchor.constraint(equalToConstant: 288).isActive = true

        let hint = NSTextField(labelWithString: "↑↓ select · ⏎ launch · esc cancel")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = ZTheme.current.fg3Color

        let manage = NSButton(title: "Manage agents…", target: self, action: #selector(manageClicked))
        manage.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [manage, NSView(), cancel])
        footer.orientation = .horizontal

        let root = NSStackView(views: [title, helper, listView, footer, hint])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalTo: listView.widthAnchor).isActive = true

        panel.contentView = root
    }

    private func activate(_ index: Int) {
        guard outcomes.indices.contains(index) else { return }
        finish(outcomes[index])
    }

    @objc private func manageClicked() { finish(.manage) }
    @objc private func cancelClicked() { finish(.cancel) }

    private func finish(_ outcome: Outcome) {
        hostWindow.endSheet(panel)
        AgentChooserSheet.active = nil
        completion(outcome)
    }
}

// MARK: - Keyboard-navigable row list

/// A vertical list of selectable rows with ↑/↓/⏎/Space/Esc and 1–9 handling.
/// `onActivate(index)` fires when a row is chosen; Esc is handled by the sheet's
/// Cancel button key equivalent.
///
/// Shared with `HibernationPlaceholderView`, so a handoff or a session is
/// picked from the same list wherever it is picked.
final class ChooserListView: NSView {

    struct Item {
        let title: String
        let icon: NSImage?
        /// The account's identity color, or nil for rows that aren't
        /// account-specific.
        var dot: NSColor?
        /// A waiting handoff: it carries a bin at its end.
        var isDeletable = false
    }

    var onActivate: ((Int) -> Void)?
    /// The bin of a deletable row was clicked.
    var onDelete: ((Int) -> Void)?
    private let isKeyboardDriven: Bool
    /// Each row's bin, nil for a row without one.
    private var bins: [NSImageView?] = []
    /// The highlighted row, or nil for none: a list that is clicked, not
    /// driven from the keyboard, has no row standing pre-selected.
    private var selected: Int?
    private var rowViews: [NSView] = []
    private var labels: [NSTextField] = []
    private var iconViews: [NSImageView] = []

    /// - Parameters:
    ///   - selectsFirstRow: false where the list is not the first responder
    ///     and nothing should look chosen until it is clicked.
    ///   - truncatesLabels: lets a long title give way instead of setting
    ///     the list's width, where that width would hold a window open.
    init(items: [Item], selectsFirstRow: Bool = true, truncatesLabels: Bool = false) {
        selected = selectsFirstRow ? 0 : nil
        isKeyboardDriven = selectsFirstRow
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for item in items {
            let row = NSView()
            row.wantsLayer = true
            row.layer?.cornerRadius = 5
            row.translatesAutoresizingMaskIntoConstraints = false

            let iconView = NSImageView()
            iconView.image = item.icon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: item.title)
            label.font = ZTheme.chromeFont(size: 12)
            label.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingTail
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = false
            if truncatesLabels { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }

            // The account's identity color, trailing. Zero-width when the row
            // isn't account-specific, so every row keeps the same constraints.
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = item.dot?.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false

            // A waiting handoff can be thrown away from here. An image, not
            // a button: the row's click recognizer takes the mouse-down
            // first, so `rowClicked` tells a click on the bin by where it
            // landed.
            var bin: NSImageView?
            if item.isDeletable {
                let view = NSImageView()
                view.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete handoff")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
                view.contentTintColor = ZTheme.current.fg3Color
                view.toolTip = "Delete this handoff. The conversation stays in the agent's own history."
                view.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(view)
                bin = view
            }
            bins.append(bin)

            // Add to the hierarchy BEFORE constraining — activation needs a
            // common ancestor.
            row.addSubview(iconView)
            row.addSubview(label)
            row.addSubview(dot)
            stack.addArrangedSubview(row)
            if let bin {
                NSLayoutConstraint.activate([
                    bin.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                    bin.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    bin.widthAnchor.constraint(equalToConstant: 16),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: bin.leadingAnchor, constant: -8),
                ])
            }
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: widthAnchor),
                row.heightAnchor.constraint(equalToConstant: 28),
                iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
                iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
                dot.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: item.dot == nil ? 0 : 6),
                dot.heightAnchor.constraint(equalToConstant: item.dot == nil ? 0 : 6),
            ])

            rowViews.append(row)
            labels.append(label)
            iconViews.append(iconView)

            let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
            row.addGestureRecognizer(click)
        }
        updateHighlight()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// Only where it was asked to be driven from the keyboard. Elsewhere a
    /// click must not leave it holding the keys: its Return and 1–9 pick.
    override var acceptsFirstResponder: Bool { isKeyboardDriven }

    @objc private func rowClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let row = recognizer.view, let index = rowViews.firstIndex(of: row) else { return }
        selected = index
        updateHighlight()
        // A little slack around the bin: it is 16pt of a 28pt row.
        if let bin = bins[index], bin.frame.insetBy(dx: -6, dy: -6).contains(recognizer.location(in: row)) {
            onDelete?(index)
            return
        }
        onActivate?(index)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // down
            selected = min((selected ?? -1) + 1, rowViews.count - 1); updateHighlight()
        case 126: // up
            selected = max((selected ?? 0) - 1, 0); updateHighlight()
        case 36, 76, 49: // return, enter, space
            if let selected { onActivate?(selected) }
        default:
            // 1–9 jump straight to that row.
            if let chars = event.characters, let digit = Int(chars), digit >= 1, digit <= rowViews.count {
                selected = digit - 1
                updateHighlight()
                onActivate?(digit - 1)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func updateHighlight() {
        for (index, row) in rowViews.enumerated() {
            let isSel = index == selected
            row.layer?.backgroundColor = isSel ? ZTheme.current.bg3Color.cgColor : NSColor.clear.cgColor
            let tint = isSel ? ZTheme.current.fgColor : ZTheme.current.fg2Color
            labels[index].textColor = tint
            iconViews[index].contentTintColor = tint
        }
    }
}
