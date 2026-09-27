import Foundation

/// Each tile's working directory, re-read only when its pane reported a change
/// — and then at most once per `minimumInterval`.
///
/// The tile footers refresh on the coalesced chrome tick, up to ten times a
/// second, and reading a pane's directory means reading its cwd file. An agent
/// animating a spinner in its title marks its pane dirty on every frame, so
/// without the interval a grid of busy agents would read sixteen files per
/// tick for directories that almost never change. A deferred re-read is not
/// dropped: the pane stays dirty and the caller is told when to come back.
public struct TileDirectoryCache: Sendable {
    /// A `cd` shows up within about a second — the spec's bar.
    public static let minimumInterval: TimeInterval = 1.0

    private var directories: [UUID: String] = [:]
    private var readAt: [UUID: Date] = [:]
    private var dirty: Set<UUID> = []

    public init() {}

    public var hasDirty: Bool { !dirty.isEmpty }

    /// The pane's title or cwd changed; its directory may have moved.
    public mutating func markDirty(_ id: UUID) {
        dirty.insert(id)
    }

    /// The pane's directory: cached when clean or read too recently, otherwise
    /// read through `read`. `retryAfter` is set when a dirty pane's re-read was
    /// deferred, and says how long until it may happen.
    public mutating func directory(for id: UUID, now: Date,
                                   read: () -> String) -> (directory: String, retryAfter: TimeInterval?) {
        if let cached = directories[id] {
            guard dirty.contains(id) else { return (cached, nil) }
            if let last = readAt[id] {
                let elapsed = now.timeIntervalSince(last)
                if elapsed < Self.minimumInterval {
                    return (cached, Self.minimumInterval - elapsed)
                }
            }
        }
        let value = read()
        directories[id] = value
        readAt[id] = now
        dirty.remove(id)
        return (value, nil)
    }

    /// Forgets panes no tile shows any more.
    public mutating func prune(keeping ids: Set<UUID>) {
        directories = directories.filter { ids.contains($0.key) }
        readAt = readAt.filter { ids.contains($0.key) }
        dirty = dirty.intersection(ids)
    }

    /// The grid closed.
    public mutating func reset() {
        self = TileDirectoryCache()
    }
}
