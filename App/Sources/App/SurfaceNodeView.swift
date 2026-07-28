import AppKit
import ZettyCore
import ZettyGhostty

// MARK: - SurfaceNodeView

/// Recursively renders a `SurfaceNode` tree as nested `NSSplitView`s.
///
/// - For `.leaf(surface)`: embeds the registry's persistent `TerminalView`
///   for that surface inside a `LeafContainerView` that draws a subtle focus
///   ring when the pane is focused.  The terminal view is never recreated
///   across re-renders; the registry guarantees identity, preserving the live
///   PTY session.
///
/// - For `.split(direction, ratio, first, second)`: creates an `NSSplitView`
///   (`isVertical = direction == .vertical`), adds the two recursively-built
///   child views, and sets the divider position from `ratio` after layout.
///
/// Pass `focusedSurfaceID` so each leaf container can draw its highlight
/// state correctly on the initial render.  Focus change detection is handled
/// at the `TerminalViewController` level via `NSWindow.firstResponder` KVO.
@MainActor
final class SurfaceNodeView: NSView {

    // MARK: - Init

    /// Build the view hierarchy for `node` using `registry`.
    ///
    /// - Parameters:
    ///   - node: The root of the sub-tree to render.
    ///   - registry: Persistent terminal-view registry.
    ///   - focusedSurfaceID: The currently focused surface; the matching leaf
    ///     draws a focus ring.
    ///   - nodePath: Branch steps from the layout root to `node`, so divider
    ///     drags can be written back to the matching split in the model.
    ///   - onRatioChange: Called when the user drags a split's divider, with
    ///     that split's path and its new first/second ratio.
    init(
        node: SurfaceNode,
        registry: SurfaceRegistry,
        focusedSurfaceID: UUID?,
        showsClose: Bool = false,
        onClose: ((UUID) -> Void)? = nil,
        onBreak: ((UUID) -> Void)? = nil,
        onSplit: ((UUID, SplitDirection) -> Void)? = nil,
        nodePath: [SplitBranch] = [],
        onRatioChange: (([SplitBranch], Double) -> Void)? = nil
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildContent(
            node: node,
            registry: registry,
            focusedSurfaceID: focusedSurfaceID,
            showsClose: showsClose,
            onClose: onClose,
            onBreak: onBreak,
            onSplit: onSplit,
            nodePath: nodePath,
            onRatioChange: onRatioChange
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // MARK: - In-place focus update

    /// Updates the focus highlight to `focusedSurfaceID` WITHOUT rebuilding the
    /// view hierarchy. Rebuilding re-parents the live terminal views, which
    /// resigns first responder and prevents the clicked pane from taking
    /// keyboard focus — so focus changes must update borders in place.
    func updateFocus(_ focusedSurfaceID: UUID?) {
        for sub in subviews {
            if let leaf = sub as? LeafContainerView {
                leaf.setFocused(leaf.surfaceID == focusedSurfaceID)
            } else if let split = sub as? RatioSplitView {
                split.updateFocus(focusedSurfaceID)
            }
        }
    }

    // MARK: - Private

    private func buildContent(
        node: SurfaceNode,
        registry: SurfaceRegistry,
        focusedSurfaceID: UUID?,
        showsClose: Bool,
        onClose: ((UUID) -> Void)?,
        onBreak: ((UUID) -> Void)?,
        onSplit: ((UUID, SplitDirection) -> Void)?,
        nodePath: [SplitBranch],
        onRatioChange: (([SplitBranch], Double) -> Void)?
    ) {
        switch node {

        case .leaf(let surface):
            let terminalView = registry.terminalView(for: surface)
            let container = LeafContainerView(
                surfaceID: surface.id,
                terminalView: terminalView,
                isFocused: surface.id == focusedSurfaceID,
                showsClose: showsClose,
                onClose: onClose,
                onBreak: onBreak,
                onSplit: onSplit
            )
            container.translatesAutoresizingMaskIntoConstraints = false
            addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: topAnchor),
                container.leadingAnchor.constraint(equalTo: leadingAnchor),
                container.trailingAnchor.constraint(equalTo: trailingAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

        case .split(let direction, let ratio, let first, let second):
            let splitView = RatioSplitView(
                direction: direction,
                ratio: ratio,
                first: first,
                second: second,
                registry: registry,
                focusedSurfaceID: focusedSurfaceID,
                showsClose: showsClose,
                onClose: onClose,
                onBreak: onBreak,
                onSplit: onSplit,
                nodePath: nodePath,
                onRatioChange: onRatioChange
            )
            splitView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(splitView)
            NSLayoutConstraint.activate([
                splitView.topAnchor.constraint(equalTo: topAnchor),
                splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
                splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
                splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
}

// MARK: - LeafContainerView

/// A thin wrapper view that embeds a `TerminalView` and floats the pane's
/// chrome — a focus status dot and action buttons — in a top gutter.
///
/// The gutter is always present so the split buttons are reachable even from a
/// lone pane. `showsClose` (true only when the tab holds more than one pane)
/// additionally reveals the break-into-tab and × buttons, which are no-ops on a
/// single pane.
@MainActor
private final class LeafContainerView: NSView {

    private static let borderWidth: CGFloat = 2
    /// Top strip reserved for the chrome buttons, so they never overlap the
    /// terminal's first line.
    private static let gutterHeight: CGFloat = 24
    /// Square edge of each gutter button.
    private static let buttonSize: CGFloat = 18

    let surfaceID: UUID
    private var isFocused: Bool
    private var onClose: ((UUID) -> Void)?
    private var onBreak: ((UUID) -> Void)?
    private var onSplit: ((UUID, SplitDirection) -> Void)?
    private var statusDot: NSView?

    init(
        surfaceID: UUID,
        terminalView: NSView,
        isFocused: Bool,
        showsClose: Bool,
        onClose: ((UUID) -> Void)?,
        onBreak: ((UUID) -> Void)? = nil,
        onSplit: ((UUID, SplitDirection) -> Void)? = nil
    ) {
        self.surfaceID = surfaceID
        self.isFocused = isFocused
        self.onClose = onClose
        self.onBreak = onBreak
        self.onSplit = onSplit
        super.init(frame: .zero)
        wantsLayer = true
        // Rounded, themed pane surface (handoff: 10pt radius panes on bg1).
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = ZTheme.current.bg1Color.cgColor

        let inset = LeafContainerView.borderWidth
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            // The gutter inset keeps the chrome buttons above the terminal
            // content instead of overlapping its first line.
            terminalView.topAnchor.constraint(equalTo: topAnchor,
                                              constant: LeafContainerView.gutterHeight),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])

        addStatusDot()
        addGutterButtons(showsClose: showsClose)
        menu = makePaneMenu(showsClose: showsClose)

        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// Updates the focus state + border in place (no rebuild).
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        updateBorder()
    }

    private func updateBorder() {
        // No pane border by design; focus is conveyed by the accent status dot.
        layer?.borderWidth = 0
        let theme = ZTheme.current
        statusDot?.layer?.backgroundColor = isFocused
            ? theme.accentColor.cgColor
            : theme.fg3Color.cgColor
    }

    /// A small status dot floated top-left in the gutter, echoing the handoff's
    /// pane header (accent when focused, dim otherwise).
    private func addStatusDot() {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
        ])
        statusDot = dot
    }

    /// Lays the gutter actions out right-to-left from the trailing edge:
    /// split-vertical · split-horizontal · break · close. The split pair is
    /// always available; break and × only when the pane is closable.
    private func addGutterButtons(showsClose: Bool) {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])

        // "2x1" = two columns (a vertical divider), "1x2" = two rows.
        stack.addArrangedSubview(makeGutterButton(
            symbol: "square.split.2x1", fallback: "⇹",
            toolTip: "Split vertically", action: #selector(splitVerticalTapped)
        ))
        stack.addArrangedSubview(makeGutterButton(
            symbol: "square.split.1x2", fallback: "⇳",
            toolTip: "Split horizontally", action: #selector(splitHorizontalTapped)
        ))

        guard showsClose else { return }
        stack.addArrangedSubview(makeGutterButton(
            symbol: "arrow.up.forward.square", fallback: "↗",
            toolTip: "Break pane into tab", action: #selector(breakButtonTapped)
        ))
        stack.addArrangedSubview(makeGutterButton(
            symbol: "xmark", fallback: "×",
            toolTip: "Close pane", action: #selector(closeButtonTapped)
        ))
    }

    private func makeGutterButton(
        symbol: String,
        fallback: String,
        toolTip: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .circular
        button.isBordered = false
        button.title = ""
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) {
            button.image = image
        } else {
            button.title = fallback
        }
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = ZTheme.current.fg3Color
        button.toolTip = toolTip
        button.target = self
        button.action = action
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: LeafContainerView.buttonSize),
            button.heightAnchor.constraint(equalToConstant: LeafContainerView.buttonSize),
        ])
        return button
    }

    @objc private func closeButtonTapped() {
        onClose?(surfaceID)
    }

    @objc private func breakButtonTapped() {
        onBreak?(surfaceID)
    }

    @objc private func splitVerticalTapped() {
        onSplit?(surfaceID, .vertical)
    }

    @objc private func splitHorizontalTapped() {
        onSplit?(surfaceID, .horizontal)
    }

    /// Right-click menu for the pane chrome (gutter). The terminal view fills
    /// the container below the gutter and handles its own right-click, so this
    /// menu appears only on the pane chrome — not over the terminal content.
    private func makePaneMenu(showsClose: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Split Vertically", #selector(splitVerticalTapped)))
        menu.addItem(makeMenuItem("Split Horizontally", #selector(splitHorizontalTapped)))
        guard showsClose else { return menu }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Break Pane into Tab", #selector(breakButtonTapped)))
        menu.addItem(makeMenuItem("Close Pane", #selector(closeButtonTapped)))
        return menu
    }

    private func makeMenuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}

// MARK: - RatioSplitView

/// An `NSSplitView` that respects a `ratio` (0…1) for its single divider.
///
/// Because `setPosition(_:ofDividerAt:)` is only meaningful after the split
/// view has a non-zero frame, the ratio is applied in `layout()` on the first
/// pass where the bounds are non-empty.  Subsequent layout calls leave the
/// divider alone so user drags are preserved.
///
/// Divider drags are written back to the model: once the initial position is
/// set, any meaningful ratio change (a drag; window resizes keep proportions)
/// is reported through `onRatioChange` with this split's `nodePath`, so the
/// persisted layout matches what's on screen.
@MainActor
private final class RatioSplitView: NSSplitView, NSSplitViewDelegate {

    private let ratio: Double
    private var didSetInitialPosition = false
    private let nodePath: [SplitBranch]
    private let onRatioChange: (([SplitBranch], Double) -> Void)?
    private var lastReportedRatio: Double

    init(
        direction: SplitDirection,
        ratio: Double,
        first: SurfaceNode,
        second: SurfaceNode,
        registry: SurfaceRegistry,
        focusedSurfaceID: UUID?,
        showsClose: Bool = false,
        onClose: ((UUID) -> Void)? = nil,
        onBreak: ((UUID) -> Void)? = nil,
        onSplit: ((UUID, SplitDirection) -> Void)? = nil,
        nodePath: [SplitBranch] = [],
        onRatioChange: (([SplitBranch], Double) -> Void)? = nil
    ) {
        self.ratio = ratio
        self.nodePath = nodePath
        self.onRatioChange = onRatioChange
        self.lastReportedRatio = ratio
        super.init(frame: .zero)
        isVertical = (direction == .vertical)
        dividerStyle = .thin
        delegate = self

        let firstView = SurfaceNodeView(
            node: first,
            registry: registry,
            focusedSurfaceID: focusedSurfaceID,
            showsClose: showsClose,
            onClose: onClose,
            onBreak: onBreak,
            onSplit: onSplit,
            nodePath: nodePath + [.first],
            onRatioChange: onRatioChange
        )
        let secondView = SurfaceNodeView(
            node: second,
            registry: registry,
            focusedSurfaceID: focusedSurfaceID,
            showsClose: showsClose,
            onClose: onClose,
            onBreak: onBreak,
            onSplit: onSplit,
            nodePath: nodePath + [.second],
            onRatioChange: onRatioChange
        )
        addArrangedSubview(firstView)
        addArrangedSubview(secondView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// Forwards an in-place focus update to both child sub-trees.
    func updateFocus(_ focusedSurfaceID: UUID?) {
        for sub in arrangedSubviews {
            (sub as? SurfaceNodeView)?.updateFocus(focusedSurfaceID)
        }
    }

    override func layout() {
        super.layout()
        applyInitialRatioIfNeeded()
    }

    private func applyInitialRatioIfNeeded() {
        guard !didSetInitialPosition else { return }
        let dimension = isVertical ? bounds.width : bounds.height
        guard dimension > 0 else { return }
        didSetInitialPosition = true
        let position = dimension * ratio
        setPosition(position, ofDividerAt: 0)
    }

    // MARK: - NSSplitViewDelegate

    func splitViewDidResizeSubviews(_: Notification) {
        // Ignore resizes until the persisted ratio has been applied, so the
        // pre-layout default position never overwrites the model.
        guard didSetInitialPosition, arrangedSubviews.count == 2 else { return }
        let dimension = isVertical ? bounds.width : bounds.height
        guard dimension > 0 else { return }
        let firstFrame = arrangedSubviews[0].frame
        let current = Double((isVertical ? firstFrame.width : firstFrame.height) / dimension)
        // Proportional window resizes wobble by sub-pixel amounts; only a real
        // divider drag moves the ratio enough to be worth writing back.
        guard abs(current - lastReportedRatio) > 0.001 else { return }
        lastReportedRatio = current
        onRatioChange?(nodePath, current)
    }
}
