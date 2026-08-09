import Foundation

/// Remembers which directories were expanded, keyed by tree root.
///
/// A pane's tree re-roots whenever its shell `cd`s, and agents `cd` constantly.
/// Without this, every hop would collapse the tree and the feature would be
/// unusable in exactly the sessions it matters most for.
///
/// Bounded LRU: only `record` counts as use, so reading the cache while
/// rebuilding a view can't distort eviction order.
public struct FileTreeExpansionCache: Sendable, Equatable {

    public let capacity: Int
    /// Roots oldest → newest.
    private var order: [String] = []
    private var expandedByRoot: [String: Set<String>] = [:]

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    public var rootCount: Int { order.count }

    public func expanded(for root: String) -> Set<String> {
        expandedByRoot[root] ?? []
    }

    public mutating func record(root: String, expanded: Set<String>) {
        expandedByRoot[root] = expanded
        order.removeAll { $0 == root }
        order.append(root)
        while order.count > capacity {
            expandedByRoot.removeValue(forKey: order.removeFirst())
        }
    }
}
