import Foundation

/// A named grid shape — the structure a tile view starts from, with no panes
/// in it.
///
/// Creating a profile COPIES this grid; the two are independent afterwards, so
/// editing a layout only affects views made later. Nothing you are looking at
/// reshapes because of something you changed elsewhere. That is also why a
/// profile keeps no back-reference: with copy semantics a "from Quad" label
/// cannot stay true across a rename or a delete, and the grid is already the
/// profile's own.
public struct TileLayout: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var grid: TilesGrid

    public init(id: UUID = UUID(), name: String, grid: TilesGrid) {
        self.id = id
        self.name = name
        self.grid = grid
    }

    /// Seeded once into a fresh library. Editable and deletable like any
    /// other — a starting point you cannot change is just clutter.
    public static let builtIns: [TileLayout] = [
        TileLayout(name: "Focus", grid: TilesGrid(columns: 1, rows: 1)),
        TileLayout(name: "Pair", grid: TilesGrid(columns: 2, rows: 1)),
        TileLayout(name: "Stack", grid: TilesGrid(columns: 1, rows: 2)),
        TileLayout(name: "Quad", grid: TilesGrid(columns: 2, rows: 2)),
        TileLayout(name: "Grid", grid: TilesGrid(columns: 4, rows: 4)),
    ]
}
