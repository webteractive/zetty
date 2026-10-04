import AppKit

/// The Zetty mark: a slab Z whose tail ends in a terminal tile.
///
/// Drawn from the same geometry as the app icon's 1024 px artwork (y down),
/// so the menu bar glyph and `AppIcon.icns` stay one shape. The icon cuts a
/// `>_` out of the tile; here it stays solid, since at menu bar size the
/// prompt would be under a point tall.
enum ZettyMark {

    private static let letter: [CGPoint] = [
        CGPoint(x: 304, y: 264), CGPoint(x: 744, y: 264), CGPoint(x: 744, y: 368),
        CGPoint(x: 476, y: 656), CGPoint(x: 594, y: 656), CGPoint(x: 594, y: 760),
        CGPoint(x: 280, y: 760), CGPoint(x: 280, y: 656), CGPoint(x: 548, y: 368),
        CGPoint(x: 280, y: 368),
    ]

    private static let tile: [CGPoint] = [
        CGPoint(x: 614, y: 656), CGPoint(x: 744, y: 656),
        CGPoint(x: 744, y: 760), CGPoint(x: 614, y: 760),
    ]

    private static let bounds = CGRect(x: 280, y: 264, width: 464, height: 496)

    /// A template image `height` points tall, tinted by the menu bar.
    static func menuBarImage(height: CGFloat = 16) -> NSImage {
        let scale = height / bounds.height
        let size = NSSize(width: (bounds.width * scale).rounded(.up), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for shape in [letter, tile] {
                let path = NSBezierPath()
                for (index, point) in shape.enumerated() {
                    let scaled = NSPoint(x: (point.x - bounds.minX) * scale,
                                         y: (point.y - bounds.minY) * scale)
                    if index == 0 { path.move(to: scaled) } else { path.line(to: scaled) }
                }
                path.close()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Zetty"
        return image
    }
}
