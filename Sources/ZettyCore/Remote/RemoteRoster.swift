import Foundation

/// Which machines the sidebar lists, given what Tailscale says now.
public enum RemoteRoster {
    /// A Mac becomes a group only once it has answered a hello (the client
    /// adds it then), so `known` grows elsewhere. This only keeps the known
    /// ones honest against Tailscale, and lists tagged Macs with the reason
    /// they can't join: a refusal explains itself rather than going missing.
    /// Connection state (online, connecting) is the client's and is left alone.
    public static func reconcile(_ known: [String: RemoteMachine],
                                 with status: TailscaleStatus) -> [String: RemoteMachine] {
        guard let me = status.me else { return known }
        var roster = known
        for node in PeerAdmission.listable(in: status) {
            if case .refuse(let reason) = PeerAdmission.decide(me: me, peer: node) {
                var machine = roster[node.stableID]
                    ?? RemoteMachine(stableID: node.stableID, name: node.hostName, state: .offline,
                                     lastSeen: node.lastSeen, workspace: nil)
                machine.state = .refused(reason.message(machine: node.hostName))
                roster[node.stableID] = machine
            } else if var machine = roster[node.stableID] {
                if case .refused = machine.state { machine.state = .offline }
                if machine.lastSeen == nil { machine.lastSeen = node.lastSeen }
                roster[node.stableID] = machine
            }
        }
        return roster
    }
}

/// Paces snapshots to at most one per `interval`, always delivering the last.
/// A running agent retitles its pane several times a second; without this
/// every tick built a snapshot on main and sent it to every peer.
public struct SnapshotThrottle {
    public enum Decision: Equatable {
        case sendNow
        /// Send once this many seconds have passed, then call `sent(at:)`.
        case sendAfter(TimeInterval)
        /// A deferred send is already coming; it will carry this change too.
        case alreadyPending
    }

    private let interval: TimeInterval
    private var lastSent: Date?
    private var pending = false

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    public mutating func offer(at now: Date) -> Decision {
        if pending { return .alreadyPending }
        if let lastSent, now.timeIntervalSince(lastSent) < interval {
            pending = true
            return .sendAfter(interval - now.timeIntervalSince(lastSent))
        }
        lastSent = now
        return .sendNow
    }

    /// The deferred send went out.
    public mutating func sent(at now: Date) {
        lastSent = now
        pending = false
    }
}
