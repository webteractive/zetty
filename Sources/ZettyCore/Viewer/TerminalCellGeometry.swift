import CoreGraphics

/// Point↔cell conversions for a terminal grid.
///
/// Two coordinate spaces meet here. Ghostty's point space is **top-left
/// origin** (row 0 at the top); AppKit views are **bottom-left origin**. Every
/// conversion between them lives in this one place, because a drift between
/// the two directions produces off-by-one selections that are invisible until
/// a user notices.
public enum TerminalCellGeometry {

    /// The centre of a cell, in ghostty's top-left-origin point space.
    public static func cellCenter(row: Int, col: Int, cellW: CGFloat, cellH: CGFloat) -> CGPoint {
        CGPoint(x: (CGFloat(col) + 0.5) * cellW, y: (CGFloat(row) + 0.5) * cellH)
    }

    /// A ghostty-space point converted to AppKit view space.
    public static func viewPoint(fromGhostty point: CGPoint, viewHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: viewHeight - point.y)
    }

    /// The cell under an AppKit view point, or nil when the point is outside
    /// the view or the metrics are degenerate.
    public static func cell(atViewPoint point: CGPoint, viewHeight: CGFloat,
                            cellW: CGFloat, cellH: CGFloat) -> (row: Int, col: Int)? {
        guard cellW > 0, cellH > 0 else { return nil }
        guard point.x >= 0, point.y >= 0, point.y <= viewHeight else { return nil }
        let ghosttyY = viewHeight - point.y
        let row = Int((ghosttyY / cellH).rounded(.down))
        let col = Int((point.x / cellW).rounded(.down))
        guard row >= 0, col >= 0 else { return nil }
        return (row, col)
    }

    /// The view-space rect covering cells `colStart…colEnd` (inclusive) on
    /// `row` — what the hover underline is drawn into.
    public static func cellSpanRect(row: Int, colStart: Int, colEnd: Int,
                                    viewHeight: CGFloat,
                                    cellW: CGFloat, cellH: CGFloat) -> CGRect {
        let ghosttyBottom = CGFloat(row) * cellH + cellH
        return CGRect(x: CGFloat(colStart) * cellW,
                      y: viewHeight - ghosttyBottom,
                      width: CGFloat(colEnd - colStart + 1) * cellW,
                      height: cellH)
    }
}
