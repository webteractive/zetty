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
    /// Caps columns and VISIBLE rows. It does not cap attachments.
    public var grid: TilesGrid
    /// nil is a hole you can attach into. May be longer than `capacity`; the
    /// view scrolls past it.
    public var slots: [TileSlot?]

    public init(id: UUID = UUID(), name: String, kind: TileProfileKind = .manual,
                grid: TilesGrid = .default, slots: [TileSlot?] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.grid = grid
        self.slots = slots
        padToCapacity()
    }

    public var capacity: Int { grid.columns * grid.rows }
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
        trimTrailingHoles()
        padToCapacity()
    }

    /// Resizing NEVER truncates `slots`. The grid caps what is visible and the
    /// view scrolls past it, so shrinking a profile's grid can never silently
    /// drop a pane.
    public mutating func setGrid(_ grid: TilesGrid) {
        self.grid = grid
        // Trim first, then pad: shrinking should not leave phantom `+ Attach`
        // cells trailing past the new capacity, but it must never reach an
        // attachment — `trimTrailingHoles` only ever removes nils.
        trimTrailingHoles()
        padToCapacity()
    }

    private mutating func padToCapacity() {
        if slots.count < capacity {
            slots.append(contentsOf: Array(repeating: nil, count: capacity - slots.count))
        }
    }

    private mutating func trimTrailingHoles() {
        while slots.count > capacity, slots.last == .some(nil) {
            slots.removeLast()
        }
    }
}

extension TileProfile {
    private enum CodingKeys: String, CodingKey { case id, name, kind, grid, slots }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown kind from a newer build degrades to manual rather than
        // throwing away the whole library.
        let kind = (try? container.decode(TileProfileKind.self, forKey: .kind)) ?? .manual
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: kind,
            grid: try container.decodeIfPresent(TilesGrid.self, forKey: .grid) ?? .default,
            slots: try container.decodeIfPresent([TileSlot?].self, forKey: .slots) ?? [])
    }
}
