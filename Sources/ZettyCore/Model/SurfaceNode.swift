import Foundation

/// One step in a path addressing a node inside a `SurfaceNode` tree.
public enum SplitBranch: Sendable, Equatable {
    case first
    case second
}

public indirect enum SurfaceNode: Codable, Sendable, Equatable {
    case leaf(Surface)
    case split(direction: SplitDirection, ratio: Double, first: SurfaceNode, second: SurfaceNode)

    /// All leaf surfaces, left-to-right / first-to-second order.
    public var surfaces: [Surface] {
        switch self {
        case .leaf(let s):
            return [s]
        case .split(_, _, let first, let second):
            return first.surfaces + second.surfaces
        }
    }
}
