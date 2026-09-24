import AppKit
import ZettyCore

/// Draws a layout tree as its own silhouette.
///
/// All that survives of the old config sheet. The sheet asked for columns and
/// rows before a view existed, which stopped making sense once a tile could be
/// split and removed from its own face — but a picture of an arrangement is
/// still how the chooser and the view menu say which one they mean.
enum TileShapeImage {

    static func make(for root: TileNode, size: CGFloat = 32) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let gap: CGFloat = 2
            ZTheme.current.fg2Color.setFill()
            // Straight from the layout engine, so a non-uniform shape draws as
            // itself rather than as the nearest grid.
            for frame in root.frames(in: LayoutRect(x: 0, y: 0, width: 1, height: 1)) {
                let cell = NSRect(
                    x: CGFloat(frame.x) * rect.width + gap / 2,
                    // LayoutRect is top-left-origin; NSImage drawing is not.
                    y: rect.height - CGFloat(frame.y + frame.height) * rect.height + gap / 2,
                    width: CGFloat(frame.width) * rect.width - gap,
                    height: CGFloat(frame.height) * rect.height - gap)
                NSBezierPath(roundedRect: cell, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        // Template, so `contentTintColor` reaches it: the chooser tints a
        // hovered card. The fill colour above is only the silhouette AppKit
        // re-tints.
        image.isTemplate = true
        return image
    }
}
