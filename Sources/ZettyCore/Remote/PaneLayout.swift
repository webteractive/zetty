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
