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
    /// The pane's project is hibernated; carries the project's name. Nothing
    /// is spawned for it — a hibernated project owns no sessions, and a tile
    /// that attached one would quietly undo the hibernation — until Wake.
    case hibernated(String)
}

// MARK: - TileStatus

/// The tile header's leading dot, carrying the agent's semantic colour.
enum TileStatus: Equatable {
    case running
    case attention
    case idle
    /// The agent's last turn ended in an API error or a refusal.
    case errored

    func color(_ theme: ZTheme) -> NSColor {
        switch self {
        case .running: return theme.greenColor
        case .attention: return theme.yellowColor
        case .idle: return theme.fg3Color
        case .errored: return theme.redColor
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
final class ClickRowView: NSView {
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
final class TileView: NSView, AgentRestartPresenting, NSDraggingSource {

    // MARK: - AgentRestartPresenting

    // Always present — a tile with no pane simply keeps it hidden, which is
    // what `setRefreshVisible(false)` does anyway.
    var restartButton: NSButton? { refreshButton }
    var restartCoverHost: NSView { terminalView ?? body }
    var restartCover: ReloadingOverlay?


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
    private let openButton = NSButton()
    private let refreshButton = NSButton()
    private let endButton = NSButton()
    private let splitDownButton = NSButton()
    private let splitRightButton = NSButton()
    private let removeSplitButton = NSButton()
    private let goToPaneButton = NSButton()
    private let body = NSView()
    /// The registry's terminal view for this tile, when it has one — the
    /// overlay must be parented onto it, not beside it.
    private weak var terminalView: NSView?
    private let messageLabel = NSTextField(labelWithString: "")
    private let statusLineView = TileStatusLineView()
    /// Only a live terminal tile has a footer: empty, missing, attaching and
    /// failed cells keep their full height for their actions and messages.
    private var hasStatusLine = false
    /// The footer's height, zeroed when the tile is too short for one.
    private var footerHeightConstraint: NSLayoutConstraint?

    /// A header drag's payload: the slot index being moved. Its own type, so
    /// the grid can tell a tile from a sidebar tab row, and so a terminal
    /// underneath — which accepts files and text — never claims the drop.
    static let slotDragType = NSPasteboard.PasteboardType("co.webteractive.zetty.tile-slot")
    /// How far the pointer travels before a press on the header is a drag
    /// rather than the click that focuses the tile.
    private static let dragThreshold: CGFloat = 4

    /// Where a press on the header began, while it may still become a drag.
    private var dragOrigin: NSPoint?
    private var isDropTarget = false

    private let canRemove: Bool
    /// What the end-session button does, nil when there is nothing to offer —
    /// then it is never added to the header, like remove-split.
    private let endAction: TileEndAction?
    private var isFocused: Bool
    private var status: TileStatus
    private let onActivate: () -> Void
    private let onGoToPane: () -> Void
    private let onOpen: (NSView) -> Void
    private let onRefresh: () -> Void
    private let onEnd: () -> Void
    private let onDetach: () -> Void
    private let onSplit: (SplitDirection) -> Void
    private let onRemoveSplit: () -> Void
    private let onAddProject: () -> Void
    private let onWake: () -> Void

    init(surfaceID: UUID?,
         slotIndex: Int,
         label: String,
         icon: NSImage?,
         status: TileStatus,
         isFocused: Bool,
         content: TileContent,
         canRemove: Bool = false,
         canRefresh: Bool = false,
         endAction: TileEndAction? = nil,
         onActivate: @escaping () -> Void,
         onGoToPane: @escaping () -> Void,
         onOpen: @escaping (NSView) -> Void = { _ in },
         onRefresh: @escaping () -> Void = {},
         onEnd: @escaping () -> Void = {},
         onDetach: @escaping () -> Void = {},
         onSplit: @escaping (SplitDirection) -> Void = { _ in },
         onRemoveSplit: @escaping () -> Void = {},
         onAddProject: @escaping () -> Void = {},
         onWake: @escaping () -> Void = {},
         statusLine: TileStatusLine? = nil,
         onAccountClicked: @escaping () -> Void = {}) {
        self.surfaceID = surfaceID
        self.slotIndex = slotIndex
        self.status = status
        self.isFocused = isFocused
        self.onActivate = onActivate
        self.onGoToPane = onGoToPane
        self.onOpen = onOpen
        self.onRefresh = onRefresh
        self.onEnd = onEnd
        self.onDetach = onDetach
        self.onSplit = onSplit
        self.onRemoveSplit = onRemoveSplit
        self.onAddProject = onAddProject
        self.onWake = onWake
        self.canRemove = canRemove
        self.endAction = endAction
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = Self.borderWidth

        // A hole has nothing to name, so it is body-only — the header would
        // be an empty strip above an empty cell.
        if case .empty = content {} else {
            buildHeader(label: label, icon: icon, canOpen: surfaceID != nil,
                        canRefresh: canRefresh)
        }
        buildBody(content: content)
        statusLineView.onAccountClicked = onAccountClicked
        if hasStatusLine { statusLineView.setLine(statusLine) }
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
            // Named after what it WILL do. One selector drives both, because
            // `removeTileSlot` branches on whether the slot is filled — but
            // calling both "Remove Slot" said the wrong thing for a filled
            // one, which only empties it and leaves the pane running.
            //
            // The empty case is omitted when there is no split to collapse:
            // `TileNode.close` refuses the last leaf, so on a fresh
            // single-slot view the item would do nothing at all.
            if surfaceID != nil || canRemove {
                menu.addItem(.separator())
                let detach = NSMenuItem(
                    title: surfaceID != nil ? "Detach Pane" : "Remove Split",
                    action: #selector(detachClicked), keyEquivalent: "")
                detach.target = self
                menu.addItem(detach)
            }
            // A filled tile can also go in one step, the same as its header
            // button: detach and collapse together.
            if surfaceID != nil, canRemove {
                let remove = NSMenuItem(title: "Remove Split", action: #selector(removeSplitClicked),
                                        keyEquivalent: "")
                remove.target = self
                menu.addItem(remove)
            }
            return menu
        }()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Build

    private func buildHeader(label: String, icon: NSImage?, canOpen: Bool,
                             canRefresh: Bool) {
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

        // Open is per tile, as it is per pane in the gutter: it is the only
        // way to reach a pane's directory from the grid. Hidden for a
        // `.missing` slot, which has no pane and therefore no directory.
        //
        // Uniform 13pt icons rather than a labelled pill and a menu: an
        // `Open ▾` label and a split MENU together ran ~160pt of a 24pt
        // header, which is most of a tile in a 4x4 grid. Icons keep the pane's
        // name readable, which is the thing you actually navigate by.
        //
        // Order is refresh · end · open · split-down · split-right ·
        // remove-split · × (end and remove-split only when they apply), and
        // the destructive ones sit apart from ×: a refresh ends the running
        // agent and end closes the pane outright, so neither may neighbour the
        // button that only detaches. Refresh leads because it is hidden
        // whenever no agent can be resumed and still holds its place: at the
        // front that is blank space beside the title, where second it was a
        // hole between open and the splits.
        buildHeaderButton(openButton, symbol: "folder", fallback: "▤",
                          tip: "Open this pane's directory in an editor or Finder",
                          action: #selector(openClicked), hidden: !canOpen)
        buildHeaderButton(refreshButton, symbol: "arrow.clockwise", fallback: "⟳",
                          tip: "Restart the agent on its existing conversation",
                          action: #selector(refreshClicked), hidden: !canRefresh)
        // End session: closes the pane, or its tab, or — for a project's only
        // pane, which cannot be closed — hibernates the project. The glyph and
        // tip say which, and the controller resolves it again on the click.
        if let endAction {
            buildHeaderButton(endButton, symbol: endAction.symbol,
                              fallback: endAction.fallbackGlyph, tip: endAction.tooltip,
                              action: #selector(endClicked), hidden: false)
        }
        buildHeaderButton(splitDownButton, symbol: "rectangle.split.1x2", fallback: "⊟",
                          tip: "Split this slot downwards (⇧⌘D)",
                          action: #selector(splitDown), hidden: false)
        buildHeaderButton(splitRightButton, symbol: "rectangle.split.2x1", fallback: "⊞",
                          tip: "Split this slot to the right (⌘D)",
                          action: #selector(splitRight), hidden: false)
        // × detaches; it does NOT close the pane. It must go through the same
        // helper as the rest: its constraints below reference `header`, and a
        // button that is never added to one has no common ancestor with its
        // neighbours — which raises NSGenericException out of `viewDidLoad`,
        // past `applicationDidFinishLaunching`, so the window is created and
        // then never ordered on screen. That shipped in 2f57b6d’s successor
        // and read as "Zetty launches invisibly".
        // Remove Split: detach AND collapse in one press, beside the × that
        // only detaches. Built only when there is a split to collapse —
        // `TileNode.close` refuses the last leaf — so a one-slot view carries
        // no button that would do nothing. Tiles are rebuilt on every
        // structural change, so `canRemove` cannot go stale on a live tile.
        if canRemove {
            let symbol = ["rectangle.split.2x1.slash", "minus.rectangle"].first {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
            } ?? "minus.rectangle"
            buildHeaderButton(removeSplitButton, symbol: symbol, fallback: "⊖",
                              tip: "Remove this split (detaches the pane, which keeps running)",
                              action: #selector(removeSplitClicked), hidden: false)
        }
        buildHeaderButton(goToPaneButton, symbol: "xmark", fallback: "×",
                          tip: "Detach from this view (the pane keeps running)",
                          action: #selector(detachClicked), hidden: false)

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
                lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -6),

            openButton.widthAnchor.constraint(equalToConstant: 13),
            openButton.heightAnchor.constraint(equalToConstant: 13),
            openButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 13),
            refreshButton.heightAnchor.constraint(equalToConstant: 13),
            refreshButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            openButton.leadingAnchor.constraint(
                equalTo: (endAction == nil ? refreshButton : endButton).trailingAnchor, constant: 7),
            splitDownButton.widthAnchor.constraint(equalToConstant: 13),
            splitDownButton.heightAnchor.constraint(equalToConstant: 13),
            splitDownButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitDownButton.leadingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: 7),
            splitRightButton.widthAnchor.constraint(equalToConstant: 13),
            splitRightButton.heightAnchor.constraint(equalToConstant: 13),
            splitRightButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitRightButton.leadingAnchor.constraint(equalTo: splitDownButton.trailingAnchor, constant: 7),

            goToPaneButton.widthAnchor.constraint(equalToConstant: 14),
            goToPaneButton.heightAnchor.constraint(equalToConstant: 14),
            goToPaneButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            goToPaneButton.trailingAnchor.constraint(equalTo: header.trailingAnchor,
                                                     constant: -8),
        ])
        // splitRight → (removeSplit →) ×. The optional button is never added
        // to the header when absent, so it cannot anchor anything.
        if endAction != nil {
            NSLayoutConstraint.activate([
                endButton.widthAnchor.constraint(equalToConstant: 13),
                endButton.heightAnchor.constraint(equalToConstant: 13),
                endButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                endButton.leadingAnchor.constraint(
                    equalTo: refreshButton.trailingAnchor, constant: 7),
            ])
        }
        if canRemove {
            NSLayoutConstraint.activate([
                removeSplitButton.widthAnchor.constraint(equalToConstant: 13),
                removeSplitButton.heightAnchor.constraint(equalToConstant: 13),
                removeSplitButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                removeSplitButton.leadingAnchor.constraint(
                    equalTo: splitRightButton.trailingAnchor, constant: 7),
                removeSplitButton.trailingAnchor.constraint(
                    equalTo: goToPaneButton.leadingAnchor, constant: -7),
            ])
        } else {
            splitRightButton.trailingAnchor.constraint(
                equalTo: goToPaneButton.leadingAnchor, constant: -7).isActive = true
        }
    }

    /// One 13pt icon button in the header. Four near-identical configuration
    /// blocks were the alternative.
    private func buildHeaderButton(_ button: NSButton, symbol: String, fallback: String,
                                   tip: String, action: Selector, hidden: Bool) {
        button.isBordered = false
        button.bezelStyle = .inline
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = fallback          // pre-SF-Symbols fallback, as the gutter does
        }
        button.target = self
        button.action = action
        button.toolTip = tip
        button.isHidden = hidden
        button.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(button)
    }

    private func buildBody(content: TileContent) {
        body.wantsLayer = true
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        let bodyTop: NSLayoutYAxisAnchor
        if case .empty = content { bodyTop = topAnchor } else { bodyTop = header.bottomAnchor }
        let bodyBottom: NSLayoutConstraint
        if case .terminal = content {
            hasStatusLine = true
            addSubview(statusLineView)
            NSLayoutConstraint.activate([
                statusLineView.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                        constant: Self.borderWidth),
                statusLineView.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                         constant: -Self.borderWidth),
                statusLineView.bottomAnchor.constraint(equalTo: bottomAnchor,
                                                       constant: -Self.borderWidth),
            ])
            let footerHeight = statusLineView.heightAnchor.constraint(
                equalToConstant: TileStatusLineView.height)
            footerHeight.isActive = true
            footerHeightConstraint = footerHeight
            bodyBottom = body.bottomAnchor.constraint(equalTo: statusLineView.topAnchor)
        } else {
            bodyBottom = body.bottomAnchor.constraint(equalTo: bottomAnchor,
                                                      constant: -Self.borderWidth)
        }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bodyTop),
            body.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: Self.borderWidth),
            body.trailingAnchor.constraint(equalTo: trailingAnchor,
                                           constant: -Self.borderWidth),
            bodyBottom,
        ])

        switch content {
        case .terminal(let terminal):
            terminalView = terminal
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
        case .hibernated(let project):
            addMessage("\(project) is hibernated")
            addWakeButton()
        }
    }

    /// Rows themed in `applyTheme` — icon and label per action row.
    private var emptyActionViews: [(NSImageView, NSTextField)] = []

    /// The empty cell's choices, stacked: Attach, Add Project, Split Right,
    /// Split Down (and Remove Split when there is a split).
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
        // Between Attach and the splits: both of the first two FILL the cell.
        // `makeActionRow` is a `ClickRowView`, which consumes its mouseDown —
        // a plain view would also reach `TileView.mouseDown` and open the
        // attach picker on top of the folder panel.
        stack.addArrangedSubview(
            makeActionRow(symbol: "folder.badge.plus", title: "Add Project") { [weak self] in
                self?.onAddProject()
            })
        stack.addArrangedSubview(
            makeActionRow(symbol: "rectangle.split.2x1", title: "Split Right") { [weak self] in
                self?.onSplit(.vertical)
            })
        stack.addArrangedSubview(
            makeActionRow(symbol: "rectangle.split.1x2", title: "Split Down") { [weak self] in
                self?.onSplit(.horizontal)
            })
        // Only when there IS one. An empty cell is the only place a split can
        // be collapsed from — a filled slot detaches first — and it has no
        // header, so without this row removal is right-click-only, which is
        // the gap splitting itself had.
        if canRemove {
            stack.addArrangedSubview(
                makeActionRow(symbol: "rectangle.split.2x1.slash",
                              title: "Remove Split") { [weak self] in
                    self?.onDetach()
                })
        }

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

    /// Its own callback, NOT `onActivate`: a mouse-down anywhere on a tile
    /// activates it, and a stray click must not wake a project.
    private func addWakeButton() {
        let button = NSButton(title: "Wake Project", target: self,
                              action: #selector(wakeClicked))
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

    @objc private func wakeClicked() { onWake() }

    @objc private func openClicked() { onOpen(openButton) }

    @objc private func refreshClicked() { onRefresh() }

    @objc private func endClicked() { onEnd() }

    // Restart chrome (button visibility, spinner, cover) comes from
    // `AgentRestartPresenting` — see the conformance below.

    @objc private func detachClicked() { onDetach() }

    @objc private func splitRight() { onSplit(.vertical) }

    @objc private func splitDown() { onSplit(.horizontal) }

    @objc private func removeSplitClicked() { onRemoveSplit() }

    // MARK: - State

    func setFocused(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        applyTheme()
    }

    /// Marks the tile a dragged one would land on. Not accent: that is the
    /// focus cue, and the dragged tile is usually the focused one.
    func setDropTarget(_ target: Bool) {
        guard isDropTarget != target else { return }
        isDropTarget = target
        applyTheme()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateFooterFit()
    }

    /// Drops the footer in a tile too short to hold it and a usable terminal —
    /// a divider drag can make one — rather than over-constrain the header,
    /// footer and body and log unsatisfiable constraints. The grid
    /// frame-positions tiles, so this is where a new height arrives.
    private func updateFooterFit() {
        guard hasStatusLine, let height = footerHeightConstraint else { return }
        let fits = TileStatusLine.fitsFooter(tileHeight: Double(bounds.height),
                                             headerHeight: Double(Self.headerHeight),
                                             border: Double(Self.borderWidth))
        guard statusLineView.isHidden == fits else { return }
        statusLineView.isHidden = !fits
        height.constant = fits ? TileStatusLineView.height : 0
    }

    /// In-place footer update — never a rebuild. No-ops on an equal line.
    func setStatusLine(_ line: TileStatusLine?) {
        guard hasStatusLine else { return }
        statusLineView.setLine(line)
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
        let border = isDropTarget ? theme.fg2Color
            : (isFocused ? theme.accentColor : theme.borderColor)
        layer?.borderColor = border.cgColor
        layer?.borderWidth = isDropTarget ? Self.borderWidth * 2 : Self.borderWidth
        // Selection/active fills are bg3 — never a saturated accent block.
        header.layer?.backgroundColor =
            (isFocused || isDropTarget ? theme.bg3Color : theme.bg0Color).cgColor
        body.layer?.backgroundColor = theme.bg1Color.cgColor
        statusDot.layer?.backgroundColor = status.color(theme).cgColor
        titleLabel.textColor = isFocused ? theme.fgColor : theme.fg2Color
        messageLabel.textColor = theme.fg3Color
        iconView.contentTintColor = isFocused ? theme.fgColor : theme.fg2Color
        goToPaneButton.contentTintColor = theme.fg3Color
        for button in [openButton, refreshButton, endButton, splitDownButton, splitRightButton,
                       removeSplitButton] {
            button.contentTintColor = theme.fg3Color
        }
        restartCover?.applyTheme()
        statusLineView.applyTheme()
        for (icon, label) in emptyActionViews {
            icon.contentTintColor = theme.fg2Color
            label.textColor = theme.fg2Color
        }
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, surfaceID != nil {
            onGoToPane()
        } else {
            onActivate()
        }
        // Only the header starts a drag: the body is the terminal, which
        // never sends its mouse events here, and an empty cell has no pane to
        // move. The header's buttons consume their own presses.
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = header.superview != nil && header.frame.contains(point)
            ? event.locationInWindow : nil
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { super.mouseDragged(with: event); return }
        let now = event.locationInWindow
        guard hypot(now.x - origin.x, now.y - origin.y) >= Self.dragThreshold else { return }
        dragOrigin = nil

        let item = NSPasteboardItem()
        item.setString(String(slotIndex), forType: Self.slotDragType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(header.frame, contents: headerSnapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        super.mouseUp(with: event)
    }

    /// The header as it looks now, to travel with the pointer: the pane's
    /// name is what says which tile is in hand.
    private func headerSnapshot() -> NSImage? {
        guard let rep = header.bitmapImageRepForCachingDisplay(in: header.bounds) else { return nil }
        header.cacheDisplay(in: header.bounds, to: rep)
        let image = NSImage(size: header.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - NSDraggingSource

    /// A tile moves within its own grid and nowhere else.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    @objc private func headerDoubleClicked() {
        guard surfaceID != nil else { return }
        onGoToPane()
    }
}
