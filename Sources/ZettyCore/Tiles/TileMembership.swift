import Foundation

/// One tile's identity and liveness, as the grid renders it.
public struct TileEntry: Equatable, Sendable {
    public let surfaceID: UUID
    /// Whether the foreground probe currently reports a real command here.
    /// A false entry still renders — dimmed, in the same slot.
    public let isBusy: Bool

    public init(surfaceID: UUID, isBusy: Bool) {
        self.surfaceID = surfaceID
        self.isBusy = isBusy
    }
}

/// The tile grid's membership rule: **sticky**.
///
/// The foreground probe re-reports every three seconds and the tiles are
/// interactive, so a grid that dropped a pane the moment it went idle would
/// remove the tile you are typing into at exactly the moment it went idle
/// waiting for you — and re-flow everything after it. Keeping the finished
/// pane visible is also usually what was wanted: it is the thing you were
/// waiting for.
///
/// Array order IS grid order. There is deliberately no sort key that could
/// disagree with it — the same reasoning `WorkspaceModel.spaces` uses for
/// sidebar order.
public enum TileMembership {

    /// - Parameters:
    ///   - previous: the current grid order. Entries keep their index.
    ///   - busy: surfaces the probe reports running a command, in a stable
    ///     caller-supplied order (workspace order). An array, not a `Set`, so
    ///     appends are deterministic.
    ///   - existing: every surface that still exists in an awake project. An
    ///     entry absent from this is dropped — the pane was closed or its
    ///     project hibernated.
    public static func update(previous: [TileEntry],
                              busy: [UUID],
                              existing: Set<UUID>) -> [TileEntry] {
        let busySet = Set(busy)
        var result = previous.compactMap { entry -> TileEntry? in
            guard existing.contains(entry.surfaceID) else { return nil }
            return TileEntry(surfaceID: entry.surfaceID,
                             isBusy: busySet.contains(entry.surfaceID))
        }
        var seen = Set(result.map(\.surfaceID))
        for id in busy where existing.contains(id) && !seen.contains(id) {
            result.append(TileEntry(surfaceID: id, isBusy: true))
            seen.insert(id)
        }
        return result
    }
}
