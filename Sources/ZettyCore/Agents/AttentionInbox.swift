import Foundation

/// Read/unread bookkeeping for the in-app attention bell.
///
/// Agent state stays the source of truth for WHO needs attention; the inbox
/// only tracks which of those the user has already seen. A read mark applies
/// to the current attention episode: when a pane leaves the needs-attention
/// set (its agent got input), the mark is dropped, so the pane's NEXT episode
/// shows as unread again.
///
/// It survives a relaunch (`AttentionInboxStore`): after the startup replay,
/// `settleAfterReplay` keeps only panes still waiting, with their read marks,
/// so an unread survivor still badges and nothing replayed counts as new.
public final class AttentionInbox {

    /// Panes currently needing attention (mirrors agent state).
    private var needsAttention: Set<UUID> = []
    /// Panes the user has seen during their current attention episode.
    private var acknowledged: Set<UUID> = []

    public init() {}

    public convenience init(snapshot: AttentionInboxSnapshot) {
        self.init()
        needsAttention = Set(snapshot.needsAttention)
        acknowledged = Set(snapshot.acknowledged).intersection(needsAttention)
    }

    /// What to persist.
    public var snapshot: AttentionInboxSnapshot {
        AttentionInboxSnapshot(needsAttention: needsAttention.sorted { $0.uuidString < $1.uuidString },
                               acknowledged: acknowledged.sorted { $0.uuidString < $1.uuidString })
    }

    /// The first sync after a relaunch's replay. A restored entry survives
    /// only if its pane is still waiting, read mark and all; a pane waiting
    /// now that the restored inbox didn't hold is replayed state, true but not
    /// news, so it starts read — unless a live report raised it (`raisedLive`)
    /// in the moments before the replay finished.
    public func settleAfterReplay(needsAttention current: Set<UUID>, raisedLive: Set<UUID> = []) {
        let restored = needsAttention
        update(needsAttention: current)
        acknowledged.formUnion(current.subtracting(restored).subtracting(raisedLive))
    }

    /// A repeat request in a pane already waiting: its episode is unread again.
    public func reopen(_ id: UUID) {
        acknowledged.remove(id)
    }

    /// Panes needing attention that the user hasn't seen yet.
    public var unread: Set<UUID> { needsAttention.subtracting(acknowledged) }

    public var unreadCount: Int { unread.count }

    /// Syncs the inbox with the current needs-attention set. Panes that left
    /// the set lose their read mark (their episode ended).
    public func update(needsAttention current: Set<UUID>) {
        needsAttention = current
        acknowledged.formIntersection(current)
    }

    /// Marks one pane's current episode as read (the user visited it).
    public func acknowledge(_ id: UUID) {
        guard needsAttention.contains(id) else { return }
        acknowledged.insert(id)
    }

    /// Marks every current episode as read ("Clear All").
    public func acknowledgeAll() {
        acknowledged = needsAttention
    }
}

/// The inbox as persisted: which panes were waiting, and which of those had
/// been seen.
public struct AttentionInboxSnapshot: Codable, Equatable, Sendable {
    public var needsAttention: [UUID]
    public var acknowledged: [UUID]

    public init(needsAttention: [UUID], acknowledged: [UUID]) {
        self.needsAttention = needsAttention
        self.acknowledged = acknowledged
    }
}
