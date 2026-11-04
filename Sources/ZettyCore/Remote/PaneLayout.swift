import Foundation

/// A tab's split tree as it crosses the wire: leaves are pane short ids, so
/// another Mac can draw the same splits around its relayed panes.
///
/// Encoded tagged, `{"pane":"ab12cd34"}` or
/// `{"split":{"direction":"vertical","ratio":0.3,"first":…,"second":…}}`.
public indirect enum PaneLayout: Codable, Equatable, Sendable {
    case pane(String)
    case split(direction: SplitDirection, ratio: Double, first: PaneLayout, second: PaneLayout)

    public init(_ node: SurfaceNode) {
        switch node {
        case .leaf(let surface):
            self = .pane(SessionPersistence.shortID(for: surface.id))
        case .split(let direction, let ratio, let first, let second):
            self = .split(direction: direction, ratio: ratio, first: PaneLayout(first), second: PaneLayout(second))
        }
    }

    /// Leaf pane ids, first-to-second order.
    public var paneIDs: [String] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, let first, let second): return first.paneIDs + second.paneIDs
        }
    }

    private enum Key: String, CodingKey { case pane, split }
    private enum SplitKey: String, CodingKey { case direction, ratio, first, second }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .pane) {
            self = .pane(id)
            return
        }
        let s = try c.nestedContainer(keyedBy: SplitKey.self, forKey: .split)
        self = .split(direction: try s.decode(SplitDirection.self, forKey: .direction),
                      ratio: try s.decode(Double.self, forKey: .ratio),
                      first: try s.decode(PaneLayout.self, forKey: .first),
                      second: try s.decode(PaneLayout.self, forKey: .second))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .pane(let id):
            try c.encode(id, forKey: .pane)
        case .split(let direction, let ratio, let first, let second):
            var s = c.nestedContainer(keyedBy: SplitKey.self, forKey: .split)
            try s.encode(direction, forKey: .direction)
            try s.encode(ratio, forKey: .ratio)
            try s.encode(first, forKey: .first)
            try s.encode(second, forKey: .second)
        }
    }
}

/// Local surface ids for another Mac's panes, stable for the life of the app
/// so a remote pane keeps its terminal across feed updates. Always fresh
/// UUIDs: a remote pane's own id would collide with nothing here, but a
/// derived one could, and these never reach the workspace or zmx.
public struct RemoteSurfaceIDs: Sendable {
    private var ids: [String: UUID] = [:]

    public init() {}

    public mutating func id(machine: String, pane: String) -> UUID {
        let key = "\(machine)/\(pane)"
        if let id = ids[key] { return id }
        let id = UUID()
        ids[key] = id
        return id
    }
}

extension PaneLayout {
    /// The most panes a remote tab shows. The tree comes from another Mac's
    /// feed, so its size is the peer's to choose; the cap bounds the views
    /// and relay processes one tab can cost here.
    public static let maxRemotePanes = 16

    /// The split tree to draw for another Mac's tab: its own layout when it
    /// sent one that names exactly the panes shown, otherwise those panes side
    /// by side. Panes whose id isn't a well-formed pane id, repeats and
    /// anything past `maxRemotePanes` are left out, and ratios are clamped.
    /// Nil for a tab with nothing left to show. Every surface starts in `/`:
    /// the peer's working directory is only a label.
    public static func surfaceTree(for tab: StatusSnapshot.Tab, ids: inout RemoteSurfaceIDs,
                                   machine: String) -> SurfaceNode? {
        var seen = Set<String>()
        let shown = Array(tab.panes.filter {
            RemoteAttachRequest(pane: $0.id, rows: 0, cols: 0, scrollback: false).isValidPane
                && seen.insert($0.id).inserted
        }.prefix(maxRemotePanes))
        guard !shown.isEmpty else { return nil }
        var leaves: [String: SurfaceNode] = [:]
        for pane in shown {
            leaves[pane.id] = .leaf(Surface(id: ids.id(machine: machine, pane: pane.id), workingDir: "/"))
        }
        if let layout = tab.layout, layout.paneIDs.count == shown.count, Set(layout.paneIDs) == Set(leaves.keys) {
            // Depth is bounded: a tree naming at most `maxRemotePanes` leaves
            // has fewer splits than that.
            func build(_ layout: PaneLayout) -> SurfaceNode {
                switch layout {
                case .pane(let id):
                    return leaves[id]!
                case .split(let direction, let ratio, let first, let second):
                    return .split(direction: direction, ratio: usableRatio(ratio), first: build(first), second: build(second))
                }
            }
            return build(layout)
        }
        // Built from the right, so the row needs no recursion.
        var node = leaves[shown[shown.count - 1].id]!
        for index in stride(from: shown.count - 2, through: 0, by: -1) {
            node = .split(direction: .vertical, ratio: 1 / Double(shown.count - index),
                          first: leaves[shown[index].id]!, second: node)
        }
        return node
    }

    /// A peer's split ratio, kept where both sides of the split stay visible.
    static func usableRatio(_ ratio: Double) -> Double {
        ratio.isFinite ? min(max(ratio, 0.05), 0.95) : 0.5
    }
}
