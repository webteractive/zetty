import AppKit
import ZettyCore

/// A keyboard-navigable modal sheet shown before a new tab/pane spawns in a
/// project with agents enabled: pick an agent to launch, a standard session,
/// manage agents, or cancel. Themed with `ZTheme`.
///
/// Keyboard: ↑/↓ move the selection, ⏎/Space launch it, Esc cancels, and 1–9
/// jump straight to that agent. Mouse clicks work too.
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

        // Row labels: each agent, then "Standard session".
        let rowTitles = agents.map(\.agent.displayName) + ["Standard session"]
        listView = ChooserListView(rowTitles: rowTitles)

        super.init()
        buildLayout()
        listView.onActivate = { [weak self] index in self?.activate(index) }
        panel.contentView?.setFrameSize(panel.contentView?.fittingSize ?? .zero)
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 320, height: 200))
        panel.initialFirstResponder = listView
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: "Launch an agent?")
        title.font = ZTheme.monoFont(size: 13)
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

    var onActivate: ((Int) -> Void)?
    private var selected = 0
    private var rows: [NSTextField] = []

    init(rowTitles: [String]) {
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
        for (index, title) in rowTitles.enumerated() {
            let label = NSTextField(labelWithString: title)
            label.font = ZTheme.monoFont(size: 12)
            label.wantsLayer = true
            label.layer?.cornerRadius = 5
            label.tag = index
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            label.heightAnchor.constraint(equalToConstant: 26).isActive = true
            // Inset the text a touch inside the highlighted pill.
            label.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingTail
            label.drawsBackground = false
            rows.append(label)
            stack.addArrangedSubview(label)

            let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
            label.addGestureRecognizer(click)
        }
        updateHighlight()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func rowClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let label = recognizer.view as? NSTextField else { return }
        selected = label.tag
        updateHighlight()
        onActivate?(selected)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // down
            selected = min(selected + 1, rows.count - 1); updateHighlight()
        case 126: // up
            selected = max(selected - 1, 0); updateHighlight()
        case 36, 76, 49: // return, enter, space
            onActivate?(selected)
        default:
            // 1–9 jump straight to that row.
            if let chars = event.characters, let digit = Int(chars), digit >= 1, digit <= rows.count {
                selected = digit - 1
                updateHighlight()
                onActivate?(selected)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func updateHighlight() {
        for (index, label) in rows.enumerated() {
            let isSel = index == selected
            label.layer?.backgroundColor = isSel ? ZTheme.current.bg3Color.cgColor : NSColor.clear.cgColor
            label.textColor = isSel ? ZTheme.current.fgColor : ZTheme.current.fg2Color
        }
    }
}
