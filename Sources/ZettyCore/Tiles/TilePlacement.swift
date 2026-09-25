import Foundation

/// Where a tab lands when something asks for it to be shown in a view that may
/// not hold it yet — `zetty focus` and `zetty tiles attach`.
public enum TilePlacement: Equatable, Sendable {
    /// Already in the view, at this slot. Nothing to change.
    case existing(Int)
    /// An empty slot to fill.
    case hole(Int)
    /// No hole: split `from` and fill the new leaf, `into`.
    case split(from: Int, into: Int)

    /// The slot the tab ends up in.
    public var slot: Int {
        switch self {
        case .existing(let index), .hole(let index): return index
        case .split(_, let into): return into
        }
    }

    /// The rule: a view already holding the tab keeps it where it is; else the
    /// first empty slot is filled; else the focused slot (or the last one when
    /// nothing is focused) is split and the new half takes it.
    ///
    /// Only slots inside the layout count as holes. `slots` can run past
    /// `capacity` in a library written before layouts were trees, and a hole
    /// out there is not on screen.
    public static func place(tabID: UUID, in profile: TileProfile,
                             focusedSlot: Int?) -> TilePlacement {
        if let index = profile.slots.firstIndex(where: { $0?.tabID == tabID }) {
            return .existing(index)
        }
        let capacity = profile.capacity
        if let hole = profile.slots.prefix(capacity).firstIndex(where: { $0 == nil }) {
            return .hole(hole)
        }
        let from = focusedSlot.flatMap { (0..<capacity).contains($0) ? $0 : nil }
            ?? max(0, capacity - 1)
        return .split(from: from, into: from + 1)
    }
}

extension TileProfile {

    /// Puts `slot` where `TilePlacement.place` says, splitting side by side
    /// when it has to. Returns the index it landed in.
    @discardableResult
    public mutating func place(_ slot: TileSlot, focusedSlot: Int?,
                               direction: SplitDirection = .vertical) -> TilePlacement {
        let placement = TilePlacement.place(tabID: slot.tabID, in: self, focusedSlot: focusedSlot)
        switch placement {
        case .existing:
            break
        case .hole(let index):
            attach(slot, at: index)
        case .split(let from, let into):
            split(at: from, direction: direction)
            attach(slot, at: into)
        }
        return placement
    }
}
