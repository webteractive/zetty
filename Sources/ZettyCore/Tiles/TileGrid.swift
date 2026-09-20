import Foundation

/// Where every tile goes, for one grid pass.
public struct TileGridLayout: Equatable, Sendable {
    public let columns: Int
    /// Total rows the tiles need — not the number visible when `scrolls`.
    public let rows: Int
    public let tileWidth: Double
    public let tileHeight: Double
    /// True when the tiles do not fit the available height and the grid
    /// scrolls at `minTileHeight` rather than shrinking past legibility.
    public let scrolls: Bool

    public init(columns: Int, rows: Int, tileWidth: Double,
                tileHeight: Double, scrolls: Bool) {
        self.columns = columns
        self.rows = rows
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.scrolls = scrolls
    }
}

/// Tile geometry: how many columns for N tiles in a given area, how big each
/// one is, and whether the result overflows.
///
/// Near-square by preference (six tiles in a wide window read better as 3x2
/// than 6x1), clamped by how many columns the width can actually hold at
/// `minTileWidth`. When the rows do not fit, the grid scrolls instead of
/// shrinking — a tile below `minTileHeight` shows too few lines to be worth
/// rendering.
public enum TileGrid {

    /// About 30 columns of mono-12 — narrow, but still a readable agent TUI.
    public static let minTileWidth: Double = 240
    /// About 10 lines. Below this a tile answers nothing.
    public static let minTileHeight: Double = 160
    public static let spacing: Double = 8

    public static func layout(count: Int,
                              width: Double,
                              height: Double,
                              minTileWidth: Double = TileGrid.minTileWidth,
                              minTileHeight: Double = TileGrid.minTileHeight,
                              spacing: Double = TileGrid.spacing) -> TileGridLayout {
        guard count > 0, width > 0, height > 0 else {
            return TileGridLayout(columns: 0, rows: 0, tileWidth: 0,
                                  tileHeight: 0, scrolls: false)
        }

        let maxColumns = max(1, Int((width + spacing) / (minTileWidth + spacing)))
        let preferred = Int(ceil(Double(count).squareRoot()))
        let columns = max(1, min(count, min(preferred, maxColumns)))
        let rows = Int(ceil(Double(count) / Double(columns)))

        let tileWidth = (width - spacing * Double(columns - 1)) / Double(columns)
        let fittingRows = max(1, Int((height + spacing) / (minTileHeight + spacing)))

        if rows <= fittingRows {
            let tileHeight = (height - spacing * Double(rows - 1)) / Double(rows)
            return TileGridLayout(columns: columns, rows: rows,
                                  tileWidth: tileWidth, tileHeight: tileHeight,
                                  scrolls: false)
        }
        return TileGridLayout(columns: columns, rows: rows,
                              tileWidth: tileWidth, tileHeight: minTileHeight,
                              scrolls: true)
    }
}
