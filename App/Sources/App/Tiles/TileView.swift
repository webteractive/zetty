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
    private static let accentBarHeight: CGFloat = 2

    let surfaceID: UUID

    private let header = NSView()
    private let accentBar = NSView()
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

    init(surfaceID: UUID,
         label: String,
         icon: NSImage?,
         status: TileStatus,
         isFocused: Bool,
         content: TileContent,
         onActivate: @escaping () -> Void,
         onGoToPane: @escaping () -> Void) {
        self.surfaceID = surfaceID
        self.status = status
        self.isFocused = isFocused
        self.onActivate = onActivate
        self.onGoToPane = onGoToPane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        buildHeader(label: label, icon: icon)
        buildBody(content: content)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Build

    private func buildHeader(label: String, icon: NSImage?) {
        // Focus is the accent top-bar — the active tab pill's anatomy — not a
        // border. Tiles stay borderless like panes.
        accentBar.wantsLayer = true
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)

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
        goToPaneButton.image = NSImage(systemSymbolName: "arrow.up.forward.square",
                                       accessibilityDescription: "Go to pane")
        goToPaneButton.imagePosition = .imageOnly
        goToPaneButton.target = self
        goToPaneButton.action = #selector(goToPaneClicked)
        goToPaneButton.toolTip = "Go to this pane"
        goToPaneButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(goToPaneButton)

        NSLayoutConstraint.activate([
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            accentBar.heightAnchor.constraint(equalToConstant: Self.accentBarHeight),

            header.topAnchor.constraint(equalTo: accentBar.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
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
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        }
    }

    /// A tile with nothing to draw must say why. An empty body is
    /// indistinguishable from a broken renderer — the lesson the file viewer's
    /// blank panel cost.
    private func addMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.font = ZTheme.chromeFont(size: 11)
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byTruncatingTail
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
        // Selection/active fills are bg3 — never a saturated accent block.
        header.layer?.backgroundColor = (isFocused ? theme.bg3Color : theme.bg0Color).cgColor
        accentBar.layer?.backgroundColor = isFocused
            ? theme.accentColor.cgColor
            : NSColor.clear.cgColor
        body.layer?.backgroundColor = theme.bg1Color.cgColor
        statusDot.layer?.backgroundColor = status.color(theme).cgColor
        titleLabel.textColor = isFocused ? theme.fgColor : theme.fg2Color
        messageLabel.textColor = theme.fg3Color
        iconView.contentTintColor = isFocused ? theme.fgColor : theme.fg2Color
        goToPaneButton.contentTintColor = theme.fg3Color
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        onActivate()
        super.mouseDown(with: event)
    }

    @objc private func goToPaneClicked() { onGoToPane() }
}
