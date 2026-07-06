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
                onBreak: onBreak
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

/// A thin wrapper view that embeds a `TerminalView` and optionally draws a
/// 2-pt accent-coloured focus ring around the pane.
///
/// When `showsClose` is true a small × button is floated in the top-right
/// corner; clicking it invokes `onClose` with this pane's `surfaceID`.
@MainActor
private final class LeafContainerView: NSView {

    private static let borderWidth: CGFloat = 2
    /// Top strip reserved for the × button when a pane is closable, so it never
    /// overlaps the terminal's first line.
    private static let closeGutterHeight: CGFloat = 24

    let surfaceID: UUID
    private var isFocused: Bool
    private var onClose: ((UUID) -> Void)?
    private var onBreak: ((UUID) -> Void)?
    private var closeButton: NSButton?
    private var breakButton: NSButton?
    private var statusDot: NSView?

    init(
        surfaceID: UUID,
        terminalView: NSView,
        isFocused: Bool,
        showsClose: Bool,
        onClose: ((UUID) -> Void)?,
        onBreak: ((UUID) -> Void)? = nil
    ) {
        self.surfaceID = surfaceID
        self.isFocused = isFocused
        self.onClose = onClose
        self.onBreak = onBreak
        super.init(frame: .zero)
        wantsLayer = true
        // Rounded, themed pane surface (handoff: 10pt radius panes on bg1).
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = ZTheme.current.bg1Color.cgColor

        let inset = LeafContainerView.borderWidth
        // Reserve a top gutter for the × when closable so it sits above the
        // terminal content instead of overlapping the first line.
        let topInset = showsClose ? LeafContainerView.closeGutterHeight : inset
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])

        if showsClose {
            addStatusDot()
            addCloseButton()
            addBreakButton()
            menu = makePaneMenu()
        }

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

    private func addCloseButton() {
        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .circular
        button.isBordered = false
        button.title = ""
        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane") {
            button.image = image
        } else {
            button.title = "×"
        }
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = ZTheme.current.fg3Color
        button.toolTip = "Close pane"
        button.target = self
        button.action = #selector(closeButtonTapped)

        addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 18),
            button.heightAnchor.constraint(equalToConstant: 18),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])

        closeButton = button
    }

    @objc private func closeButtonTapped() {
        onClose?(surfaceID)
    }

    /// A break-into-tab button that sits just left of the × in the gutter,
    /// shown alongside the close button when the pane is closable.
    private func addBreakButton() {
        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .circular
        button.isBordered = false
        button.title = ""
        if let image = NSImage(systemSymbolName: "arrow.up.forward.square",
                               accessibilityDescription: "Break pane into tab") {
            button.image = image
        } else {
            button.title = "↗"
        }
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = ZTheme.current.fg3Color
        button.toolTip = "Break pane into tab"
        button.target = self
        button.action = #selector(breakButtonTapped)

        addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 18),
            button.heightAnchor.constraint(equalToConstant: 18),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            // Sit just left of the × (× trailing = -4, width 18, +4 gap).
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
        ])

        breakButton = button
    }

    @objc private func breakButtonTapped() {
        onBreak?(surfaceID)
    }

    /// Right-click menu for the pane chrome (gutter). The terminal view fills
    /// the container below the gutter and handles its own right-click, so this
    /// menu appears only on the pane chrome — not over the terminal content.
    private func makePaneMenu() -> NSMenu {
        let menu = NSMenu()
        let breakItem = NSMenuItem(title: "Break Pane into Tab",
                                   action: #selector(breakButtonTapped),
                                   keyEquivalent: "")
        breakItem.target = self
        menu.addItem(breakItem)
        let closeItem = NSMenuItem(title: "Close Pane",
                                   action: #selector(closeButtonTapped),
                                   keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)
        return menu
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
