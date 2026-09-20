import AppKit
import ZettyCore

/// The draggable boundary between the two halves of one split.
///
/// Invisible by design — the 12pt gap between tiles already reads as the
/// divider, so this only needs to be grabbable. It reports the ratio on every
/// step but flags only the LAST one as final: persisting per mouse-move would
/// write the library to disk and rebuild chrome dozens of times a second.
@MainActor
final class TileDividerView: NSView {

    /// index, ratio, isFinal. Only the final call is persisted.
    var onDrag: ((Int, Double, Bool) -> Void)?

    private var index = 0
    private var direction: SplitDirection = .vertical
    /// The rect the SPLIT occupies, in this view's superview coordinates —
    /// the ratio is measured across it, not across the handle.
    private var splitRect: NSRect = .zero
    /// The last ratio reported mid-drag, replayed on mouse-up as the final,
    /// persisted one.
    private var lastRatio: Double?

    func configure(index: Int, direction: SplitDirection, splitRect: NSRect) {
        self.index = index
        self.direction = direction
        self.splitRect = splitRect
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: direction == .vertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        let ratio: Double
        switch direction {
        case .vertical:
            guard splitRect.width > 0 else { return }
            ratio = Double((point.x - splitRect.minX) / splitRect.width)
        case .horizontal:
            guard splitRect.height > 0 else { return }
            // Top-left-origin ratio out of a bottom-left-origin point.
            ratio = Double((splitRect.maxY - point.y) / splitRect.height)
        }
        lastRatio = ratio
        onDrag?(index, ratio, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let ratio = lastRatio else { return }
        lastRatio = nil
        onDrag?(index, ratio, true)
    }

    /// Swallowed so a drag on the boundary never reaches the tile underneath
    /// and steals focus mid-resize.
    override func mouseDown(with event: NSEvent) {}
}
