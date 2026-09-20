import Foundation

// MARK: - TileSlot

/// One attachment in a tile view: which tab, in which project.
///
/// Keyed by canonical `rootPath` + `PaneTree.id`, NOT by names. Project names
/// are not unique (unlike Space names), and a tab's display title is
/// regenerated from its running agent every second.
public struct TileSlot: Codable, Equatable, Sendable {
    public var projectRoot: String
    public var tabID: UUID
    /// The display name as it was when attached, shown when the slot can no
    /// longer be resolved — so a missing pane says what it was rather than
    /// leaving a silent gap.
    public var label: String

    public init(projectRoot: String, tabID: UUID, label: String) {
        self.projectRoot = projectRoot
        self.tabID = tabID
        self.label = label
    }
}

// MARK: - TileProfileKind

public enum TileProfileKind: String, Codable, Sendable {
    case manual
    /// Slots are computed from `TileMembership` at render time, not stored.
    case allRunning
}

// MARK: - TileProfile

/// A tile view, saved. An OPEN view is this same object — edits write through
/// immediately, so there is no template/instance split and no save step.
public struct TileProfile: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TileProfileKind
    /// The layout tree. Its leaves, in first-to-second order, ARE the slot
    /// indices below.
    public var root: TileNode
    /// nil is a hole you can attach into. May be longer than `capacity`; the
    /// view scrolls past it.
    public var slots: [TileSlot?]

    public init(id: UUID = UUID(), name: String, kind: TileProfileKind = .manual,
                root: TileNode = TileNode.uniform(.default), slots: [TileSlot?] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.root = root
        self.slots = slots
        padToCapacity()
    }

    /// A uniform profile — `TilesGrid` is a constructor for a tree now, not a
    /// shape of its own.
    public init(id: UUID = UUID(), name: String, kind: TileProfileKind = .manual,
                grid: TilesGrid, slots: [TileSlot?] = []) {
        self.init(id: id, name: name, kind: kind,
                  root: TileNode.uniform(grid), slots: slots)
    }

    public var capacity: Int { root.leafCount }
    public var attachmentCount: Int { slots.compactMap { $0 }.count }

    /// Fills one slot, growing the list when the index is past the end.
    public mutating func attach(_ slot: TileSlot, at index: Int) {
        guard index >= 0 else { return }
        if index >= slots.count {
            slots.append(contentsOf: Array(repeating: nil, count: index - slots.count + 1))
        }
        slots[index] = slot
    }

    /// Empties one slot. Deliberately leaves a HOLE rather than compacting: the
    /// slot you cleared is the one you are about to refill, and shuffling every
    /// later tile sideways under the cursor is exactly the churn the sticky
    /// membership rule exists to avoid.
    public mutating func detach(at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = nil
    }

    /// Divides a slot in two. The new leaf is `index + 1`, so its hole goes
    /// there — that is what keeps every later attachment with its own leaf.
    public mutating func split(at index: Int, direction: SplitDirection) {
        guard root.split(at: index, direction: direction) else { return }
        slots.insert(nil, at: min(index + 1, slots.count))
        padToCapacity()
    }

    /// Removes a slot and collapses its split.
    public mutating func close(at index: Int) {
        guard root.close(at: index) else { return }
        if slots.indices.contains(index) { slots.remove(at: index) }
        padToCapacity()
    }

    public mutating func setRatio(atDivider index: Int, to ratio: Double) {
        root.setRatio(atDivider: index, to: ratio)
    }

    private mutating func padToCapacity() {
        if slots.count < capacity {
            slots.append(contentsOf: Array(repeating: nil, count: capacity - slots.count))
        }
    }

}

extension TileProfile {
    private enum CodingKeys: String, CodingKey { case id, name, kind, grid, root, slots }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown kind from a newer build degrades to manual rather than
        // throwing away the whole library.
        let kind = (try? container.decode(TileProfileKind.self, forKey: .kind)) ?? .manual
        let root: TileNode
        if let stored = try container.decodeIfPresent(TileNode.self, forKey: .root) {
            root = stored
        } else {
            // Written before layouts were trees.
            root = TileNode.uniform(
                try container.decodeIfPresent(TilesGrid.self, forKey: .grid) ?? .default)
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: kind,
            root: root,
            slots: try container.decodeIfPresent([TileSlot?].self, forKey: .slots) ?? [])
    }

    /// Writes `root` only. The legacy `grid` key is read for migration and
    /// never written back, so a file converts itself the first time it is saved.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(root, forKey: .root)
        try container.encode(slots, forKey: .slots)
    }
}
