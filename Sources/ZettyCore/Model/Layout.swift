import Foundation

public struct Layout: Codable, Sendable, Equatable {
    public var root: SurfaceNode

    public init(root: SurfaceNode) {
        self.root = root
    }

    public var surfaces: [Surface] { root.surfaces }

    /// Replace the leaf with `surfaceID` by a binary split of the existing
    /// surface (first) and `newSurface` (second). Returns false if not found.
    @discardableResult
    public mutating func split(
        surfaceID: UUID,
        direction: SplitDirection,
        newSurface: Surface,
        ratio: Double = 0.5
    ) -> Bool {
        var changed = false
        root = Self.transform(root) { node in
            guard case let .leaf(existing) = node, existing.id == surfaceID else { return nil }
            changed = true
            return .split(direction: direction, ratio: ratio,
                          first: .leaf(existing), second: .leaf(newSurface))
        }
        return changed
    }

    /// Remove the leaf with `surfaceID`, collapsing its parent split to the
    /// sibling. Returns false if it's the only surface or not found.
    @discardableResult
    public mutating func close(surfaceID: UUID) -> Bool {
        // The root being the target leaf means it's the only surface.
        if case let .leaf(s) = root, s.id == surfaceID { return false }
        var changed = false
        root = Self.collapse(root, removing: surfaceID, changed: &changed)
        return changed
    }

    /// Set the ratio of the split at `path`, addressed from the root by
    /// first/second branch steps. An empty path targets the root. Returns
    /// false when the path doesn't land on a split.
    @discardableResult
    public mutating func setRatio(at path: [SplitBranch], to ratio: Double) -> Bool {
        let clamped = min(max(ratio, 0.05), 0.95)
        guard let updated = Self.settingRatio(of: root, at: path[...], to: clamped) else {
            return false
        }
        root = updated
        return true
    }

    /// Set the ratio of the split that directly contains the leaf `surfaceID`.
    @discardableResult
    public mutating func setRatio(parentOf surfaceID: UUID, to ratio: Double) -> Bool {
        let clamped = min(max(ratio, 0.05), 0.95)
        var changed = false
        root = Self.transform(root) { node in
            guard case let .split(direction, _, first, second) = node else { return nil }
            let directlyContains =
                (first.isLeaf(surfaceID) || second.isLeaf(surfaceID))
            guard directlyContains else { return nil }
            changed = true
            return .split(direction: direction, ratio: clamped, first: first, second: second)
        }
        return changed
    }

    /// Mutate the leaf surface with `surfaceID` in place (e.g. its persisted
    /// title). Returns false if no such leaf exists.
    @discardableResult
    public mutating func update(surfaceID: UUID, _ mutate: (inout Surface) -> Void) -> Bool {
        var changed = false
        root = Self.transform(root) { node in
            guard case .leaf(var surface) = node, surface.id == surfaceID else { return nil }
            mutate(&surface)
            changed = true
            return .leaf(surface)
        }
        return changed
    }

    // MARK: - Recursion helpers

    /// Returns `node` with the split at `path` given the new `ratio`, or nil
    /// when the path runs into a leaf (no split to resize).
    private static func settingRatio(
        of node: SurfaceNode,
        at path: ArraySlice<SplitBranch>,
        to ratio: Double
    ) -> SurfaceNode? {
        guard case let .split(direction, oldRatio, first, second) = node else { return nil }
        guard let step = path.first else {
            return .split(direction: direction, ratio: ratio, first: first, second: second)
        }
        let rest = path.dropFirst()
        switch step {
        case .first:
            guard let updated = settingRatio(of: first, at: rest, to: ratio) else { return nil }
            return .split(direction: direction, ratio: oldRatio, first: updated, second: second)
        case .second:
            guard let updated = settingRatio(of: second, at: rest, to: ratio) else { return nil }
            return .split(direction: direction, ratio: oldRatio, first: first, second: updated)
        }
    }

    /// Top-down (pre-order) rewrite: apply `rewrite` to each node; if it returns a
    /// replacement, use it, else recurse into children.
    private static func transform(
        _ node: SurfaceNode,
        _ rewrite: (SurfaceNode) -> SurfaceNode?
    ) -> SurfaceNode {
        if let replacement = rewrite(node) { return replacement }
        switch node {
        case .leaf:
            return node
        case let .split(direction, ratio, first, second):
            return .split(direction: direction, ratio: ratio,
                          first: transform(first, rewrite),
                          second: transform(second, rewrite))
        }
    }

    /// Remove `surfaceID`; a split whose child is the removed leaf collapses to
    /// its sibling.
    private static func collapse(
        _ node: SurfaceNode,
        removing surfaceID: UUID,
        changed: inout Bool
    ) -> SurfaceNode {
        switch node {
        case .leaf:
            return node
        case let .split(direction, ratio, first, second):
            if first.isLeaf(surfaceID) { changed = true; return second }
            if second.isLeaf(surfaceID) { changed = true; return first }
            return .split(direction: direction, ratio: ratio,
                          first: collapse(first, removing: surfaceID, changed: &changed),
                          second: collapse(second, removing: surfaceID, changed: &changed))
        }
    }
}

extension SurfaceNode {
    /// True if this node is a leaf holding `id`.
    func isLeaf(_ id: UUID) -> Bool {
        if case let .leaf(s) = self { return s.id == id }
        return false
    }
}
