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

// MARK: - ClickRowView

/// A row that CONSUMES its own click.
///
/// A plain `NSView`'s `mouseDown` forwards up the responder chain, so a row
/// inside the empty cell would reach `TileView.mouseDown` as well and open the
/// attach picker on top of whatever the row did. Deliberately not a gesture
/// recogniser: whether one swallows the underlying `mouseDown` depends on
/// `delaysPrimaryMouseButtonEvents`, and "Split Down also opened the picker"
/// is not a thing to leave to that.
@MainActor
private final class ClickRowView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }
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
    private let splitButton = NSButton()
    private let openPill = NSView()
    private let openIcon = NSImageView()
    private let openLabel = NSTextField(labelWithString: "Open")
    private let openChevron = NSImageView()
    private let goToPaneButton = NSButton()
    private let body = NSView()
    private let messageLabel = NSTextField(labelWithString: "")

    private var isFocused: Bool
    private var status: TileStatus
    private let onActivate: () -> Void
    private let onGoToPane: () -> Void
    private let onOpen: (NSView) -> Void
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
         onOpen: @escaping (NSView) -> Void = { _ in },
         onDetach: @escaping () -> Void = {},
         onSplit: @escaping (SplitDirection) -> Void = { _ in }) {
        self.surfaceID = surfaceID
        self.slotIndex = slotIndex
        self.status = status
        self.isFocused = isFocused
        self.onActivate = onActivate
        self.onGoToPane = onGoToPane
        self.onOpen = onOpen
        self.onDetach = onDetach
        self.onSplit = onSplit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = Self.borderWidth

        // A hole has nothing to name, so it is body-only — the header would
        // be an empty strip above an empty cell.
        if case .empty = content {} else {
            buildHeader(label: label, icon: icon, canOpen: surfaceID != nil)
        }
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

    private func buildHeader(label: String, icon: NSImage?, canOpen: Bool) {
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

        // The status bar's `Open ▾` folds away in tile mode, so this pill is
        // the only way to reach a pane's directory from the grid. It carries
        // the same anatomy the bar's pill had — icon, label, chevron — so it
        // reads as the control people already know.
        //
        // An NSTextField and a click recogniser rather than an NSButton with
        // an `attributedTitle`: that setter leaks an AppKit KVO dependency
        // quartet per assignment, which is the same reason the status bar's
        // own chip is a text field. Hidden for a `.missing` slot, which has no
        // pane and therefore no directory.
        // ONE button popping the slot menu this view already builds, rather
        // than a Split Right and a Split Down of its own: the header is at
        // capacity with the Open pill, and two more glyphs would be paid for
        // out of the title. Splitting is not a per-second action, so the extra
        // click is cheaper than a truncated pane name.
        splitButton.isBordered = false
        splitButton.bezelStyle = .inline
        splitButton.image = NSImage(systemSymbolName: "square.split.2x1",
                                    accessibilityDescription: "Split or remove this slot")
        splitButton.imagePosition = .imageOnly
        splitButton.target = self
        splitButton.action = #selector(splitMenuClicked)
        splitButton.toolTip = "Split or remove this slot"
        splitButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(splitButton)

        openPill.wantsLayer = true
        openPill.layer?.cornerRadius = 8
        openPill.layer?.borderWidth = 1
        openPill.isHidden = !canOpen
        openPill.toolTip = "Open this pane's directory in an editor or Finder"
        openPill.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(openPill)

        openIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        openIcon.imageScaling = .scaleProportionallyDown
        openIcon.translatesAutoresizingMaskIntoConstraints = false
        openPill.addSubview(openIcon)

        openLabel.font = ZTheme.chromeFont(size: 10)
        // The pill keeps its width and the TITLE truncates — a half-truncated
        // "Op…" is not a control, whereas a shortened pane name still reads.
        openLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        openLabel.translatesAutoresizingMaskIntoConstraints = false
        openPill.addSubview(openLabel)

        openChevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        openChevron.imageScaling = .scaleProportionallyDown
        openChevron.translatesAutoresizingMaskIntoConstraints = false
        openPill.addSubview(openChevron)

        openPill.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(openClicked)))

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
                lessThanOrEqualTo: splitButton.leadingAnchor, constant: -6),

            splitButton.widthAnchor.constraint(equalToConstant: 13),
            splitButton.heightAnchor.constraint(equalToConstant: 13),
            splitButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitButton.trailingAnchor.constraint(equalTo: openPill.leadingAnchor,
                                                  constant: -7),

            // The pill hugs its contents; a `.missing` header collapses it to
            // nothing rather than removing the view, so both lay out the same
            // way — the 0↔width toggle the account dots use.
            openPill.heightAnchor.constraint(equalToConstant: canOpen ? 16 : 0),
            openPill.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            openPill.trailingAnchor.constraint(equalTo: goToPaneButton.leadingAnchor,
                                               constant: canOpen ? -8 : 0),

            openIcon.leadingAnchor.constraint(equalTo: openPill.leadingAnchor, constant: 6),
            openIcon.centerYAnchor.constraint(equalTo: openPill.centerYAnchor),
            openIcon.widthAnchor.constraint(equalToConstant: canOpen ? 9 : 0),
            openIcon.heightAnchor.constraint(equalToConstant: 9),

            openLabel.leadingAnchor.constraint(equalTo: openIcon.trailingAnchor, constant: 4),
            openLabel.centerYAnchor.constraint(equalTo: openPill.centerYAnchor),

            openChevron.leadingAnchor.constraint(equalTo: openLabel.trailingAnchor, constant: 4),
            openChevron.centerYAnchor.constraint(equalTo: openPill.centerYAnchor),
            openChevron.widthAnchor.constraint(equalToConstant: canOpen ? 7 : 0),
            openChevron.heightAnchor.constraint(equalToConstant: 7),
            openChevron.trailingAnchor.constraint(equalTo: openPill.trailingAnchor,
                                                  constant: canOpen ? -6 : 0),

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
            buildEmptyActions()
        case .missing(let label):
            addMessage("\(label)\nnot found")
            addReattachButton()
        }
    }

    /// Rows themed in `applyTheme` — icon and label per action row.
    private var emptyActionViews: [(NSImageView, NSTextField)] = []

    /// The empty cell's three choices, stacked.
    ///
    /// This is the whole of a fresh Freeform view, so it is where someone looks
    /// to find out what a tile view can do — and until now it offered a single
    /// `+ Attach` label, leaving splitting to a right-click or `Ctrl+B %`.
    ///
    /// Stacked rather than side by side, and labelled rather than icon-only:
    /// two labels in a row need about 180pt and clip in a 4x4 grid, whereas one
    /// per row needs about 90pt and survives; and a bare split glyph is not
    /// self-evident, which is the wrong bet in the one place a first-time user
    /// is looking for the answer.
    private func buildEmptyActions() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)

        stack.addArrangedSubview(
            makeActionRow(symbol: "plus", title: "Attach") { [weak self] in
                self?.onActivate()
            })
        stack.addArrangedSubview(
            makeActionRow(symbol: "rectangle.split.2x1", title: "Split Right") { [weak self] in
                self?.onSplit(.vertical)
            })
        stack.addArrangedSubview(
            makeActionRow(symbol: "rectangle.split.1x2", title: "Split Down") { [weak self] in
                self?.onSplit(.horizontal)
            })

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: body.leadingAnchor,
                                           constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor,
                                            constant: -6),
        ])
    }

    /// An icon+label row that behaves as a button. A text field and a click
    /// recogniser rather than an `NSButton` with an `attributedTitle`, for the
    /// same reason the Open pill is one — that setter leaks an AppKit KVO
    /// dependency quartet per assignment.
    private func makeActionRow(symbol: String, title: String,
                               _ onClick: @escaping () -> Void) -> NSView {
        let row = ClickRowView()
        row.onClick = onClick
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)

        let label = NSTextField(labelWithString: title)
        label.font = ZTheme.chromeFont(size: 11)
        label.lineBreakMode = .byTruncatingTail
        // Yields before the cell does: a clipped row is still better than a
        // constraint that fights the tile's own width in a dense grid.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 11),
            icon.heightAnchor.constraint(equalToConstant: 11),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 16),
        ])
        emptyActionViews.append((icon, label))
        return row
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

    @objc private func openClicked() { onOpen(openPill) }

    /// Pops the slot menu built in `init`, so Split Right / Split Down /
    /// Remove Slot have exactly one definition and the button cannot drift
    /// from the right-click that offers the same three things.
    @objc private func splitMenuClicked() {
        guard let menu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: splitButton.bounds.height + 4), in: splitButton)
    }

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

    /// Internal, not private: a scheme change reuses the grid that owns this
    /// tile, so `TileGridView.applyTheme()` has to be able to restyle it.
    func applyTheme() {
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
        splitButton.contentTintColor = theme.fg3Color
        for (icon, label) in emptyActionViews {
            icon.contentTintColor = theme.fg2Color
            label.textColor = theme.fg2Color
        }
        // Same ramp as the status bar's pill: bg2 on bg0 chrome, bordered.
        openPill.layer?.backgroundColor = theme.bg2Color.cgColor
        openPill.layer?.borderColor = theme.borderColor.cgColor
        openIcon.contentTintColor = theme.fg2Color
        openLabel.textColor = theme.fg2Color
        openChevron.contentTintColor = theme.fg2Color
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
