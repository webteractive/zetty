import Foundation

/// A focus-move direction on screen (up = toward the top of the window).
public enum FocusDirection: Sendable, Equatable {
    case left, right, up, down
}

/// A plain rectangle in the layout's normalized, top-left-origin coordinate
/// space (x grows right, y grows down). Deliberately not `CGRect` so
/// `ZettyCore` stays free of CoreGraphics (Linux later).
public struct LayoutRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
}

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

    /// Adjust the ratio of the nearest ancestor split of `surfaceID` whose
    /// orientation matches `direction`, by `delta` (clamped like `setRatio`).
    /// Drives keyboard pane resizing: vertical splits respond to left/right,
    /// horizontal splits to up/down. Returns false when the leaf doesn't
    /// exist or no ancestor has that orientation.
    @discardableResult
    public mutating func nudgeRatio(closestTo surfaceID: UUID, direction: SplitDirection, by delta: Double) -> Bool {
        guard let fullPath = Self.path(to: surfaceID, in: root) else { return false }
        for length in stride(from: fullPath.count - 1, through: 0, by: -1) {
            let prefix = Array(fullPath.prefix(length))
            if case let .split(dir, ratio, _, _)? = node(at: prefix), dir == direction {
                return setRatio(at: prefix, to: ratio + delta)
            }
        }
        return false
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

    // MARK: - Directional navigation

    /// Normalized leaf frames in a unit square with a top-left origin
    /// (x grows right, y grows down — matching how `SurfaceNodeView` lays
    /// splits out: `.vertical` cuts the x-axis with `first` on the left,
    /// `.horizontal` cuts the y-axis with `first` on top).
    public func frames(in rect: LayoutRect = LayoutRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: LayoutRect] {
        Self.collectFrames(of: root, in: rect)
    }

    /// The leaf best matching a focus move from `id` toward `direction`:
    /// candidates share an edge-adjacent band beyond the source frame's edge
    /// with perpendicular overlap; the largest overlap wins, ties break to the
    /// topmost/leftmost. Nil when `id` is unknown or nothing lies that way.
    public func neighbor(of id: UUID, direction: FocusDirection) -> UUID? {
        let allFrames = frames()
        guard let source = allFrames[id] else { return nil }

        var best: (id: UUID, overlap: Double, position: Double)?
        for (candidateID, frame) in allFrames where candidateID != id {
            let beyond: Bool
            let overlap: Double
            switch direction {
            case .left:
                beyond = frame.maxX <= source.minX + 0.0001
                overlap = overlapLength(frame.minY ..< frame.maxY, source.minY ..< source.maxY)
            case .right:
                beyond = frame.minX >= source.maxX - 0.0001
                overlap = overlapLength(frame.minY ..< frame.maxY, source.minY ..< source.maxY)
            case .up:
                beyond = frame.maxY <= source.minY + 0.0001
                overlap = overlapLength(frame.minX ..< frame.maxX, source.minX ..< source.maxX)
            case .down:
                beyond = frame.minY >= source.maxY - 0.0001
                overlap = overlapLength(frame.minX ..< frame.maxX, source.minX ..< source.maxX)
            }
            guard beyond, overlap > 0 else { continue }
            let position = direction == .left || direction == .right ? frame.minY : frame.minX
            if let current = best {
                if overlap > current.overlap ||
                    (overlap == current.overlap && position < current.position) {
                    best = (candidateID, overlap, position)
                }
            } else {
                best = (candidateID, overlap, position)
            }
        }
        return best?.id
    }

    private func overlapLength(_ a: Range<Double>, _ b: Range<Double>) -> Double {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    private static func collectFrames(of node: SurfaceNode, in rect: LayoutRect) -> [UUID: LayoutRect] {
        switch node {
        case .leaf(let surface):
            return [surface.id: rect]
        case let .split(direction, ratio, first, second):
            let firstRect: LayoutRect
            let secondRect: LayoutRect
            switch direction {
            case .vertical:      // side-by-side: cut the x-axis
                let cut = rect.width * ratio
                firstRect = LayoutRect(x: rect.minX, y: rect.minY, width: cut, height: rect.height)
                secondRect = LayoutRect(x: rect.minX + cut, y: rect.minY, width: rect.width - cut, height: rect.height)
            case .horizontal:    // stacked: cut the y-axis, first on top
                let cut = rect.height * ratio
                firstRect = LayoutRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut)
                secondRect = LayoutRect(x: rect.minX, y: rect.minY + cut, width: rect.width, height: rect.height - cut)
            }
            return collectFrames(of: first, in: firstRect)
                .merging(collectFrames(of: second, in: secondRect)) { a, _ in a }
        }
    }

    // MARK: - Recursion helpers

    /// Branch steps from the root to the leaf holding `surfaceID`, or nil.
    private static func path(to surfaceID: UUID, in node: SurfaceNode) -> [SplitBranch]? {
        switch node {
        case .leaf(let surface):
            return surface.id == surfaceID ? [] : nil
        case .split(_, _, let first, let second):
            if let rest = path(to: surfaceID, in: first) { return [.first] + rest }
            if let rest = path(to: surfaceID, in: second) { return [.second] + rest }
            return nil
        }
    }

    /// The node reached by walking `path` from the root, or nil if the path
    /// steps into a leaf.
    private func node(at path: [SplitBranch]) -> SurfaceNode? {
        var current = root
        for step in path {
            guard case let .split(_, _, first, second) = current else { return nil }
            current = (step == .first) ? first : second
        }
        return current
    }

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
