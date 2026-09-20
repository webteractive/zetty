import Foundation

/// A tile layout: a binary split tree, deliberately the same shape as
/// `SurfaceNode`, with `frames(in:)` mirroring the subdivision `Layout` already
/// does for panes.
///
/// "Basically 1|1 but each column can be split" — and it does not stop at one
/// level, because unlimited nesting is ONE rule ("split the focused slot")
/// where a depth cap needs refusal logic and an explanation for why this split
/// is allowed and that one is not.
///
/// **Leaves in first-to-second order are the slot indices**, which is what lets
/// `TileProfile.slots` stay the flat array everything else is built on.
public indirect enum TileNode: Codable, Equatable, Sendable {
    case slot
    case split(direction: SplitDirection, ratio: Double, first: TileNode, second: TileNode)

    /// A divider the view can draw and drag: which split, where, and which way.
    public struct Divider: Equatable, Sendable {
        public let index: Int
        public let direction: SplitDirection
        /// The rect the split occupies — the divider sits at `ratio` across it.
        public let rect: LayoutRect
        public let ratio: Double
    }

    /// Ratios are clamped here as well as on write, so a hand-edited file can
    /// never produce a zero-sized slot.
    public static let minRatio = 0.05
    public static let maxRatio = 0.95

    public var leafCount: Int {
        switch self {
        case .slot: return 1
        case .split(_, _, let first, let second): return first.leafCount + second.leafCount
        }
    }

    public var depth: Int {
        switch self {
        case .slot: return 0
        case .split(_, _, let first, let second): return 1 + max(first.depth, second.depth)
        }
    }

    // MARK: - Geometry

    /// One rect per leaf, in slot order.
    public func frames(in rect: LayoutRect) -> [LayoutRect] {
        switch self {
        case .slot:
            return [rect]
        case .split(let direction, let ratio, let first, let second):
            let (a, b) = Self.divide(rect, direction: direction, ratio: ratio)
            return first.frames(in: a) + second.frames(in: b)
        }
    }

    /// Every split, pre-order, so the view can draw a handle per divider and
    /// name it back by index.
    public func dividers(in rect: LayoutRect) -> [Divider] {
        var result: [Divider] = []
        var next = 0
        Self.collectDividers(self, rect, &next, &result)
        return result
    }

    private static func collectDividers(_ node: TileNode, _ rect: LayoutRect,
                                        _ next: inout Int, _ result: inout [Divider]) {
        guard case .split(let direction, let ratio, let first, let second) = node else { return }
        let index = next
        next += 1
        result.append(Divider(index: index, direction: direction, rect: rect,
                              ratio: clamp(ratio)))
        let (a, b) = divide(rect, direction: direction, ratio: ratio)
        collectDividers(first, a, &next, &result)
        collectDividers(second, b, &next, &result)
    }

    private static func divide(_ rect: LayoutRect, direction: SplitDirection,
                               ratio: Double) -> (LayoutRect, LayoutRect) {
        let ratio = clamp(ratio)
        switch direction {
        case .vertical:
            let width = rect.width * ratio
            return (LayoutRect(x: rect.x, y: rect.y, width: width, height: rect.height),
                    LayoutRect(x: rect.x + width, y: rect.y,
                               width: rect.width - width, height: rect.height))
        case .horizontal:
            let height = rect.height * ratio
            return (LayoutRect(x: rect.x, y: rect.y, width: rect.width, height: height),
                    LayoutRect(x: rect.x, y: rect.y + height,
                               width: rect.width, height: rect.height - height))
        }
    }

    private static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, minRatio), maxRatio)
    }

    // MARK: - Construction

    /// A uniform grid as a tree: rows stacked, each divided into columns.
    /// `TilesGrid` is now a CONSTRUCTOR for this, not a shape of its own.
    ///
    /// The chained ratio is `1/remaining`, not `1/2` — otherwise three columns
    /// would come out 1/2, 1/4, 1/4 instead of even thirds.
    public static func uniform(columns: Int, rows: Int) -> TileNode {
        func chain(_ count: Int, _ direction: SplitDirection,
                   _ leaf: @escaping () -> TileNode) -> TileNode {
            guard count > 1 else { return leaf() }
            return .split(direction: direction, ratio: 1.0 / Double(count),
                          first: leaf(),
                          second: chain(count - 1, direction, leaf))
        }
        let columns = max(1, columns)
        let rows = max(1, rows)
        return chain(rows, .horizontal) { chain(columns, .vertical) { .slot } }
    }

    public static func uniform(_ grid: TilesGrid) -> TileNode {
        uniform(columns: grid.columns, rows: grid.rows)
    }

    // MARK: - Mutation

    /// Replaces leaf `index` with a split of two leaves. The new leaf becomes
    /// `index + 1`, which is why `TileProfile.split` inserts a hole there —
    /// that is what keeps every later attachment with its own leaf.
    @discardableResult
    public mutating func split(at index: Int, direction: SplitDirection) -> Bool {
        guard index >= 0, index < leafCount else { return false }
        var remaining = index
        self = Self.splitting(self, &remaining, direction)
        return true
    }

    private static func splitting(_ node: TileNode, _ remaining: inout Int,
                                  _ direction: SplitDirection) -> TileNode {
        switch node {
        case .slot:
            guard remaining == 0 else { remaining -= 1; return node }
            remaining -= 1
            return .split(direction: direction, ratio: 0.5, first: .slot, second: .slot)
        case .split(let d, let ratio, let first, let second):
            let updatedFirst = splitting(first, &remaining, direction)
            let updatedSecond = splitting(second, &remaining, direction)
            return .split(direction: d, ratio: ratio, first: updatedFirst, second: updatedSecond)
        }
    }

    /// Removes leaf `index`, collapsing its parent split into the sibling.
    /// Refused for the only leaf: a view with no slots has nothing to show and
    /// no way back.
    @discardableResult
    public mutating func close(at index: Int) -> Bool {
        guard leafCount > 1, index >= 0, index < leafCount else { return false }
        var remaining = index
        self = Self.removing(&remaining, from: self) ?? .slot
        return true
    }

    private static func removing(_ remaining: inout Int, from node: TileNode) -> TileNode? {
        switch node {
        case .slot:
            if remaining == 0 { return nil }
            remaining -= 1
            return node
        case .split(let direction, let ratio, let first, let second):
            let firstLeaves = first.leafCount
            if remaining < firstLeaves {
                guard let kept = removing(&remaining, from: first) else { return second }
                return .split(direction: direction, ratio: ratio, first: kept, second: second)
            }
            remaining -= firstLeaves
            guard let kept = removing(&remaining, from: second) else { return first }
            return .split(direction: direction, ratio: ratio, first: first, second: kept)
        }
    }

    /// Sets one divider's ratio, addressed the way `dividers(in:)` numbers
    /// them — a leaf index would be ambiguous, since a leaf has many ancestor
    /// splits and only one of them owns the handle being dragged.
    @discardableResult
    public mutating func setRatio(atDivider index: Int, to ratio: Double) -> Bool {
        guard index >= 0 else { return false }
        var next = 0
        var done = false
        self = Self.settingRatio(self, index, Self.clamp(ratio), &next, &done)
        return done
    }

    private static func settingRatio(_ node: TileNode, _ target: Int, _ ratio: Double,
                                     _ next: inout Int, _ done: inout Bool) -> TileNode {
        guard case .split(let direction, let existing, let first, let second) = node else {
            return node
        }
        let index = next
        next += 1
        let newRatio: Double
        if index == target {
            newRatio = ratio
            done = true
        } else {
            newRatio = existing
        }
        let updatedFirst = settingRatio(first, target, ratio, &next, &done)
        let updatedSecond = settingRatio(second, target, ratio, &next, &done)
        return .split(direction: direction, ratio: newRatio,
                      first: updatedFirst, second: updatedSecond)
    }
}
