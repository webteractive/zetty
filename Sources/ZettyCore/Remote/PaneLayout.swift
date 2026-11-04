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
    /// The split tree to draw for another Mac's tab: its own layout when it
    /// sent one that names exactly its panes, otherwise its panes side by side.
    /// Nil for a tab with no panes. The working directory is only a label;
    /// the relay ignores it.
    public static func surfaceTree(for tab: StatusSnapshot.Tab, ids: inout RemoteSurfaceIDs,
                                   machine: String) -> SurfaceNode? {
        guard !tab.panes.isEmpty else { return nil }
        let panes = Dictionary(tab.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func leaf(_ pane: StatusSnapshot.Pane) -> SurfaceNode {
            .leaf(Surface(id: ids.id(machine: machine, pane: pane.id), workingDir: pane.cwd ?? "/"))
        }
        if let layout = tab.layout, Set(layout.paneIDs) == Set(panes.keys), layout.paneIDs.count == panes.count {
            func build(_ layout: PaneLayout) -> SurfaceNode {
                switch layout {
                case .pane(let id):
                    return leaf(panes[id]!)
                case .split(let direction, let ratio, let first, let second):
                    return .split(direction: direction, ratio: ratio, first: build(first), second: build(second))
                }
            }
            return build(layout)
        }
        func row(_ rest: ArraySlice<StatusSnapshot.Pane>) -> SurfaceNode {
            guard rest.count > 1 else { return leaf(rest.first!) }
            return .split(direction: .vertical, ratio: 1 / Double(rest.count),
                          first: leaf(rest.first!), second: row(rest.dropFirst()))
        }
        return row(tab.panes[...])
    }
}
