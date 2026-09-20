import AppKit
import ZettyCore

// MARK: - TileContent

/// What a tile is currently showing.
enum TileContent {
    /// The registry's real terminal view for this surface.
    case terminal(NSView)
    /// The pane has a live session but no surface yet — it is in the spawn
    /// queue. See `TerminalViewController.tileSpawnInterval`.
    case attaching
    /// The spawn failed; the reason is shown instead of a false "attaching".
    case failed(String)
    /// A hole — the `+ Attach` cell that makes an empty grid explain itself.
    case empty
    /// The slot's project or tab is gone; carries the remembered label.
    case missing(String)
}

// MARK: - TileStatus

/// The tile header's leading dot, carrying the agent's semantic colour.
enum TileStatus: Equatable {
    case running
    case attention
    case idle

    func color(_ theme: ZTheme) -> NSColor {
        switch self {
        case .running: return theme.greenColor
        case .attention: return theme.yellowColor
        case .idle: return theme.fg3Color
        }
    }
}

// MARK: - TileView

/// One cell of the tile grid: a header strip naming the pane, above the pane's
/// real terminal view.
///
/// The terminal view is the registry's own `AppTerminalView` — the same object
/// the normal pane layout hosts — so typing into a focused tile reaches the pty
/// with no forwarding of any kind. That is the whole mechanism.
@MainActor
final class TileView: NSView {

    static let headerHeight: CGFloat = 24
    private static let borderWidth: CGFloat = 1

    /// nil for a hole or a missing slot — neither has a pane.
    let surfaceID: UUID?
    /// Position in the profile: what attach and detach address.
    let slotIndex: Int

    private let header = NSView()
    private let statusDot = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let goToPaneButton = NSButton()
    private let body = NSView()
    private let messageLabel = NSTextField(labelWithString: "")

    private var isFocused: Bool
    private var status: TileStatus
    private let onActivate: () -> Void
    private let onGoToPane: () -> Void
    private let onDetach: () -> Void
    private let onSplit: (SplitDirection) -> Void

    init(surfaceID: UUID?,
         slotIndex: Int,
         label: String,
         icon: NSImage?,
         status: TileStatus,
         isFocused: Bool,
         content: TileContent,
         onActivate: @escaping () -> Void,
         onGoToPane: @escaping () -> Void,
         onDetach: @escaping () -> Void = {},
         onSplit: @escaping (SplitDirection) -> Void = { _ in }) {
        self.surfaceID = surfaceID
        self.slotIndex = slotIndex
        self.status = status
        self.isFocused = isFocused
        self.onActivate = onActivate
        self.onGoToPane = onGoToPane
        self.onDetach = onDetach
        self.onSplit = onSplit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = Self.borderWidth

        // A hole has nothing to name, so it is body-only — the header would
        // be an empty strip above an empty cell.
        if case .empty = content {} else { buildHeader(label: label, icon: icon) }
        buildBody(content: content)
        // The live grid is the layout editor, so a slot splits like a pane.
        menu = {
            let menu = NSMenu()
            let right = NSMenuItem(title: "Split Right", action: #selector(splitRight),
                                   keyEquivalent: "")
            right.target = self
            menu.addItem(right)
            let down = NSMenuItem(title: "Split Down", action: #selector(splitDown),
                                  keyEquivalent: "")
            down.target = self
            menu.addItem(down)
            menu.addItem(.separator())
            let detach = NSMenuItem(title: "Remove Slot", action: #selector(detachClicked),
                                    keyEquivalent: "")
            detach.target = self
            menu.addItem(detach)
            return menu
        }()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Build

    private func buildHeader(label: String, icon: NSImage?) {
        header.wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(statusDot)

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(iconView)

        // Chrome font, never mono: the tile is chrome, so the terminal font
        // must not reflow the grid.
        titleLabel.stringValue = label
        titleLabel.font = ZTheme.chromeFont(size: 11)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        goToPaneButton.isBordered = false
        goToPaneButton.bezelStyle = .inline
        goToPaneButton.image = NSImage(systemSymbolName: "xmark",
                                       accessibilityDescription: "Detach from this view")
        goToPaneButton.imagePosition = .imageOnly
        goToPaneButton.target = self
        goToPaneButton.action = #selector(detachClicked)
        goToPaneButton.toolTip = "Detach from this view (the pane keeps running)"
        goToPaneButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(goToPaneButton)

        // Double-clicking the HEADER leaves tile mode for this pane. It has to
        // be the header: the body is the terminal view, which consumes its own
        // mouse events, so a click there never reaches this view at all.
        let jump = NSClickGestureRecognizer(target: self, action: #selector(headerDoubleClicked))
        jump.numberOfClicksRequired = 2
        header.addGestureRecognizer(jump)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor,
                                        constant: Self.borderWidth),
            header.leadingAnchor.constraint(equalTo: leadingAnchor,
                                            constant: Self.borderWidth),
            header.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -Self.borderWidth),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            statusDot.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusDot.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),

            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),

            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: goToPaneButton.leadingAnchor, constant: -6),

            goToPaneButton.widthAnchor.constraint(equalToConstant: 14),
            goToPaneButton.heightAnchor.constraint(equalToConstant: 14),
            goToPaneButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            goToPaneButton.trailingAnchor.constraint(equalTo: header.trailingAnchor,
                                                     constant: -8),
        ])
    }

    private func buildBody(content: TileContent) {
        body.wantsLayer = true
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        let bodyTop: NSLayoutYAxisAnchor
        if case .empty = content { bodyTop = topAnchor } else { bodyTop = header.bottomAnchor }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bodyTop),
            body.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: Self.borderWidth),
            body.trailingAnchor.constraint(equalTo: trailingAnchor,
                                           constant: -Self.borderWidth),
            body.bottomAnchor.constraint(equalTo: bottomAnchor,
                                         constant: -Self.borderWidth),
        ])

        switch content {
        case .terminal(let terminal):
            terminal.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.topAnchor.constraint(equalTo: body.topAnchor),
                terminal.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                terminal.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            ])
        case .attaching:
            addMessage("attaching\u{2026}")
        case .failed(let reason):
            addMessage(reason)
        case .empty:
            addMessage("+ Attach")
        case .missing(let label):
            addMessage("\(label)\nnot found")
            addReattachButton()
        }
    }

    /// A tile with nothing to draw must say why. An empty body is
    /// indistinguishable from a broken renderer — the lesson the file viewer's
    /// blank panel cost.
    private func addMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.font = ZTheme.chromeFont(size: 11)
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: body.leadingAnchor,
                                                  constant: 8),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor,
                                                   constant: -8),
        ])
    }

    /// A missing slot is actionable, not just informative — the pane it named
    /// may exist again under a new tab, and re-picking it is one click. It
    /// calls the same `onActivate` a hole does, so Reattach and `+ Attach` are
    /// literally one path.
    private func addReattachButton() {
        let button = NSButton(title: "Reattach\u{2026}", target: self,
                              action: #selector(reattachClicked))
        button.isBordered = false
        button.font = ZTheme.chromeFont(size: 11)
        button.contentTintColor = ZTheme.current.accentColor
        button.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            button.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 6),
        ])
    }

    @objc private func reattachClicked() { onActivate() }

    @objc private func detachClicked() { onDetach() }

    @objc private func splitRight() { onSplit(.vertical) }

    @objc private func splitDown() { onSplit(.horizontal) }

    // MARK: - State

    func setFocused(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        applyTheme()
    }

    func setStatus(_ newStatus: TileStatus) {
        guard status != newStatus else { return }
        status = newStatus
        applyTheme()
    }

    private func applyTheme() {
        let theme = ZTheme.current
        layer?.backgroundColor = theme.bg1Color.cgColor
        // A grid of sixteen terminals needs the separation two panes do not,
        // and borders are chrome's sanctioned depth mechanism. The border also
        // carries focus, so there is one accent signal rather than two.
        layer?.borderColor = (isFocused ? theme.accentColor : theme.borderColor).cgColor
        // Selection/active fills are bg3 — never a saturated accent block.
        header.layer?.backgroundColor = (isFocused ? theme.bg3Color : theme.bg0Color).cgColor
        body.layer?.backgroundColor = theme.bg1Color.cgColor
        statusDot.layer?.backgroundColor = status.color(theme).cgColor
        titleLabel.textColor = isFocused ? theme.fgColor : theme.fg2Color
        messageLabel.textColor = theme.fg3Color
        iconView.contentTintColor = isFocused ? theme.fgColor : theme.fg2Color
        goToPaneButton.contentTintColor = theme.fg3Color
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, surfaceID != nil {
            onGoToPane()
        } else {
            onActivate()
        }
        super.mouseDown(with: event)
    }

    @objc private func headerDoubleClicked() {
        guard surfaceID != nil else { return }
        onGoToPane()
    }
}
