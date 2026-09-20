import Foundation

/// How many tiles fit on one screenful, from `zetty-tiles-grid`.
///
/// A **cap**, not a fixed cell count: below capacity tiles grow near-square to
/// fill the window, and at or above it the grid is exactly this shape and
/// scrolls. So the setting answers "never smaller than this" — which is the
/// only thing a grid of live terminals needs it to answer.
public struct TilesGrid: Equatable, Sendable, Codable {
    public let columns: Int
    public let rows: Int

    public static let `default` = TilesGrid(columns: 4, rows: 4)
    /// 8x8 is 64 tiles. Past that a tile cannot show a line of text, and the
    /// clamp keeps a hand-edited config from producing a grid of slivers.
    public static let maxSide = 8

    public init(columns: Int, rows: Int) {
        self.columns = min(max(columns, 1), Self.maxSide)
        self.rows = min(max(rows, 1), Self.maxSide)
    }

    /// Parses `<cols>x<rows>`. Returns nil rather than guessing — the caller
    /// keeps the default, because ghostty validates all-or-nothing and a typo
    /// must never cost the whole config.
    public init?(parsing text: String) {
        let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let columns = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let rows = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              columns > 0, rows > 0
        else { return nil }
        self.init(columns: columns, rows: rows)
    }

    public var configValue: String { "\(columns)x\(rows)" }

    private enum CodingKeys: String, CodingKey { case columns, rows }

    /// Routed through the clamping initialiser — a synthesized decoder would
    /// bypass it, and a hand-edited 99x99 must not produce a grid of slivers.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(columns: try container.decode(Int.self, forKey: .columns),
                  rows: try container.decode(Int.self, forKey: .rows))
    }
}

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

    /// A last-resort clamp, NOT the working minimum — `zetty-tiles-grid` is.
    /// It was 240 while the column count was derived from the width, which
    /// capped an 828pt window at three columns and made the default 4x4
    /// unreachable. At 120 it binds only near the 320pt window floor.
    public static let minTileWidth: Double = 120
    /// About 10 lines. Below this a tile answers nothing.
    public static let minTileHeight: Double = 160
    /// Wide enough to read as a gap between two terminals rather than a seam.
    public static let spacing: Double = 12

    public static func layout(count: Int,
                              width: Double,
                              height: Double,
                              grid: TilesGrid = .default,
                              minTileWidth: Double = TileGrid.minTileWidth,
                              minTileHeight: Double = TileGrid.minTileHeight,
                              spacing: Double = TileGrid.spacing) -> TileGridLayout {
        guard count > 0, width > 0, height > 0 else {
            return TileGridLayout(columns: 0, rows: 0, tileWidth: 0,
                                  tileHeight: 0, scrolls: false)
        }

        let widthAllows = max(1, Int((width + spacing) / (minTileWidth + spacing)))
        let preferred = Int(ceil(Double(count).squareRoot()))
        let columns = max(1, min(count, preferred, grid.columns, widthAllows))
        let rows = Int(ceil(Double(count) / Double(columns)))

        let tileWidth = (width - spacing * Double(columns - 1)) / Double(columns)
        let heightAllows = max(1, Int((height + spacing) / (minTileHeight + spacing)))
        let visibleRows = max(1, min(grid.rows, heightAllows))

        // Whether it scrolls or not, the rows on screen split the height
        // between them. Pinning a scrolling grid to `minTileHeight` instead
        // would leave a dead stripe below the last visible row.
        let shownRows = min(rows, visibleRows)
        let tileHeight = (height - spacing * Double(shownRows - 1)) / Double(shownRows)
        return TileGridLayout(columns: columns, rows: rows,
                              tileWidth: tileWidth, tileHeight: tileHeight,
                              scrolls: rows > visibleRows)
    }
}
