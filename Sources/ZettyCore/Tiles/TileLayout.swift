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
    public var root: TileNode

    public init(id: UUID = UUID(), name: String, root: TileNode) {
        self.id = id
        self.name = name
        self.root = root
    }

    public init(id: UUID = UUID(), name: String, grid: TilesGrid) {
        self.init(id: id, name: name, root: TileNode.uniform(grid))
    }

    private enum CodingKeys: String, CodingKey { case id, name, grid, root }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let root: TileNode
        if let stored = try container.decodeIfPresent(TileNode.self, forKey: .root) {
            root = stored
        } else {
            // Written before layouts were trees.
            root = TileNode.uniform(
                try container.decodeIfPresent(TilesGrid.self, forKey: .grid) ?? .default)
        }
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  name: try container.decode(String.self, forKey: .name),
                  root: root)
    }

    /// Writes `root` only — see the note on `TileProfile.encode`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(root, forKey: .root)
    }

    /// Seeded once into a fresh library. Editable and deletable like any
    /// other — a starting point you cannot change is just clutter.
    public static let builtIns: [TileLayout] = [
        // The one layout with no shape, and the reason a single leaf is back
        // after "Focus" was dropped for being "just the pane". That judged it
        // as a DESTINATION; this is a STARTING POINT. You do not sit in it —
        // you split it into whatever the work needs, which is the one thing
        // the six preset shapes cannot offer, since each of them commits you
        // to its shape before you know what you are arranging.
        TileLayout(name: "Freeform", root: .slot),
        TileLayout(name: "Pair", grid: TilesGrid(columns: 2, rows: 1)),
        TileLayout(name: "Stack", grid: TilesGrid(columns: 1, rows: 2)),
        TileLayout(name: "Quad", grid: TilesGrid(columns: 2, rows: 2)),
        TileLayout(name: "Grid", grid: TilesGrid(columns: 4, rows: 4)),
        // Expressible only now that a layout is a tree: 1|2/3.
        TileLayout(name: "Main + Two", root: .split(
            direction: .vertical, ratio: 0.5,
            first: .slot,
            second: .split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot))),
        TileLayout(name: "Two + Main", root: .split(
            direction: .vertical, ratio: 0.5,
            first: .split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot),
            second: .slot)),
    ]
}
