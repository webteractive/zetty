import AppKit
import ZettyCore

/// A keyboard-navigable modal sheet shown before a new tab/pane spawns in a
/// project with agents enabled: pick an agent to launch, a standard session,
/// manage agents, or cancel. Themed with `ZTheme`.
///
/// Keyboard: ↑/↓ move the selection, ⏎/Space launch it, Esc cancels, and 1–9
/// jump straight to that agent. Mouse clicks work too.
@MainActor
final class AgentChooserSheet: NSObject {

    enum Outcome {
        case agent(String)   // launch this command
        case standard        // plain session
        case manage          // open Project Settings → Agents
        case cancel          // do nothing
    }

    /// Keeps the sheet alive for the duration of the modal.
    private static var active: AgentChooserSheet?

    private let panel: NSWindow
    private let hostWindow: NSWindow
    private let agents: [ResolvedSpawnAgent]
    private let completion: (Outcome) -> Void
    private let listView: ChooserListView

    static func present(
        agents: [ResolvedSpawnAgent],
        on window: NSWindow,
        completion: @escaping (Outcome) -> Void
    ) {
        let sheet = AgentChooserSheet(agents: agents, host: window, completion: completion)
        active = sheet
        window.beginSheet(sheet.panel)
    }

    private init(agents: [ResolvedSpawnAgent], host: NSWindow, completion: @escaping (Outcome) -> Void) {
        self.agents = agents
        self.hostWindow = host
        self.completion = completion

        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 10),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.appearance = ZTheme.current.appearance
        panel.backgroundColor = ZTheme.current.bg1Color
        panel.titlebarAppearsTransparent = true
        panel.title = ""

        // Rows: each agent (with its logo), then "Standard session" (terminal).
        var items = agents.map { resolved -> ChooserListView.Item in
            let icon = AgentIcons.icon(forTool: resolved.agent.id)
                ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            return ChooserListView.Item(title: resolved.agent.displayName, icon: icon)
        }
        let terminalIcon = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        items.append(ChooserListView.Item(title: "Standard session", icon: terminalIcon))
        listView = ChooserListView(items: items)

        super.init()
        buildLayout()
        listView.onActivate = { [weak self] index in self?.activate(index) }
        let fit = panel.contentView?.fittingSize ?? .zero
        panel.setContentSize(fit == .zero ? NSSize(width: 320, height: 200) : fit)
        panel.initialFirstResponder = listView
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: "Launch an agent?")
        title.font = ZTheme.chromeFont(size: 13)
        title.textColor = ZTheme.current.accentColor

        let helper = NSTextField(wrappingLabelWithString:
            "This project has agents enabled. Pick one to launch here, or continue "
            + "with a standard session.")
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
        if index >= 0, index < agents.count {
            finish(.agent(agents[index].command))
        } else {
            finish(.standard)
        }
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
private final class ChooserListView: NSView {

    struct Item { let title: String; let icon: NSImage? }

    var onActivate: ((Int) -> Void)?
    private var selected = 0
    private var rowViews: [NSView] = []
    private var labels: [NSTextField] = []
    private var iconViews: [NSImageView] = []

    init(items: [Item]) {
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

            // Add to the hierarchy BEFORE constraining — activation needs a
            // common ancestor.
            row.addSubview(iconView)
            row.addSubview(label)
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: widthAnchor),
                row.heightAnchor.constraint(equalToConstant: 28),
                iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
                iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -8),
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

    override var acceptsFirstResponder: Bool { true }

    @objc private func rowClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let row = recognizer.view, let index = rowViews.firstIndex(of: row) else { return }
        selected = index
        updateHighlight()
        onActivate?(index)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // down
            selected = min(selected + 1, rowViews.count - 1); updateHighlight()
        case 126: // up
            selected = max(selected - 1, 0); updateHighlight()
        case 36, 76, 49: // return, enter, space
            onActivate?(selected)
        default:
            // 1–9 jump straight to that row.
            if let chars = event.characters, let digit = Int(chars), digit >= 1, digit <= rowViews.count {
                selected = digit - 1
                updateHighlight()
                onActivate?(selected)
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
