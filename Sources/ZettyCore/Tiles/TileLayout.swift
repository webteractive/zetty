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
    ///
    /// Only Freeform ships now. Every preset below was expressible by
    /// splitting it, so seven cards were seven ways of saying "here is a shape
    /// you could have made in two clicks"; the tree model is what made them
    /// redundant rather than convenient.
    public static let builtIns: [TileLayout] = [
        TileLayout(name: "Freeform", root: .slot),
    ]

    /// Built-ins that shipped once and were withdrawn, kept so a library that
    /// already has them can be cleaned up.
    ///
    /// Carries the ROOT as well as the name, and `seedMissingLayouts` requires
    /// both to match before removing one. A layout the user edited keeps their
    /// name but not the shipped shape, and deleting that would be deleting
    /// their work — irreversibly, since nothing here is undoable.
    public static let retiredBuiltIns: [(name: String, root: TileNode)] = [
        ("Focus", .slot),
        ("Pair", TileNode.uniform(TilesGrid(columns: 2, rows: 1))),
        ("Stack", TileNode.uniform(TilesGrid(columns: 1, rows: 2))),
        ("Quad", TileNode.uniform(TilesGrid(columns: 2, rows: 2))),
        ("Grid", TileNode.uniform(TilesGrid(columns: 4, rows: 4))),
        ("Main + Two", .split(
            direction: .vertical, ratio: 0.5,
            first: .slot,
            second: .split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot))),
        ("Two + Main", .split(
            direction: .vertical, ratio: 0.5,
            first: .split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot),
            second: .slot)),
    ]
}
