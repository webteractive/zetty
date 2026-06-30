import AppKit
import QuerttyCore
import QuerttyGhostty

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
    init(
        node: SurfaceNode,
        registry: SurfaceRegistry,
        focusedSurfaceID: UUID?
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildContent(node: node, registry: registry, focusedSurfaceID: focusedSurfaceID)
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
        focusedSurfaceID: UUID?
    ) {
        switch node {

        case .leaf(let surface):
            let terminalView = registry.terminalView(for: surface)
            let container = LeafContainerView(
                surfaceID: surface.id,
                terminalView: terminalView,
                isFocused: surface.id == focusedSurfaceID
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
                focusedSurfaceID: focusedSurfaceID
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
@MainActor
private final class LeafContainerView: NSView {

    private static let borderWidth: CGFloat = 2

    let surfaceID: UUID
    private var isFocused: Bool

    init(surfaceID: UUID, terminalView: NSView, isFocused: Bool) {
        self.surfaceID = surfaceID
        self.isFocused = isFocused
        super.init(frame: .zero)
        wantsLayer = true

        let inset = LeafContainerView.borderWidth
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])

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
        if isFocused {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = LeafContainerView.borderWidth
        } else {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
            layer?.borderWidth = 0.5
        }
    }
}

// MARK: - RatioSplitView

/// An `NSSplitView` that respects a `ratio` (0…1) for its single divider.
///
/// Because `setPosition(_:ofDividerAt:)` is only meaningful after the split
/// view has a non-zero frame, the ratio is applied in `layout()` on the first
/// pass where the bounds are non-empty.  Subsequent layout calls leave the
/// divider alone so user drags are preserved.
@MainActor
private final class RatioSplitView: NSSplitView {

    private let ratio: Double
    private var didSetInitialPosition = false

    init(
        direction: SplitDirection,
        ratio: Double,
        first: SurfaceNode,
        second: SurfaceNode,
        registry: SurfaceRegistry,
        focusedSurfaceID: UUID?
    ) {
        self.ratio = ratio
        super.init(frame: .zero)
        isVertical = (direction == .vertical)
        dividerStyle = .thin

        let firstView = SurfaceNodeView(
            node: first,
            registry: registry,
            focusedSurfaceID: focusedSurfaceID
        )
        let secondView = SurfaceNodeView(
            node: second,
            registry: registry,
            focusedSurfaceID: focusedSurfaceID
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
}
