import Foundation

/// Which machines the sidebar lists, given what Tailscale says now.
public enum RemoteRoster {
    /// A Mac becomes a group only once it has answered a hello (the client
    /// adopts it then), so `known` grows elsewhere. This keeps the known ones
    /// honest against Tailscale: a machine whose node has left the tailnet
    /// (an ended test copy, a device removed in the admin console) goes, and
    /// tagged Zettys are listed with the reason they can't join, keyed by
    /// node until a hello names them. Connection state (online, connecting)
    /// is the client's and is left alone.
    public static func reconcile(_ known: [String: RemoteMachine],
                                 with status: TailscaleStatus) -> [String: RemoteMachine] {
        guard let me = status.me else { return known }
        let present = Set(status.peers.map(\.stableID))
        var roster = known.filter { _, machine in machine.node.map(present.contains) ?? false }
        for node in PeerAdmission.listable(in: status) {
            let key = roster.first(where: { $0.value.node == node.stableID })?.key
            if case .refuse(let reason) = PeerAdmission.decide(me: me, peer: node) {
                let id = key ?? node.stableID
                var machine = roster[id]
                    ?? RemoteMachine(stableID: id, name: node.hostName, state: .offline,
                                     lastSeen: node.lastSeen, workspace: nil, node: node.stableID)
                machine.state = .refused(reason.message(machine: node.hostName))
                roster[id] = machine
            } else if let key, var machine = roster[key] {
                if case .refused = machine.state { machine.state = .offline }
                if machine.lastSeen == nil { machine.lastSeen = node.lastSeen }
                roster[key] = machine
            }
        }
        return roster
    }

    /// A hello arrived from `node` naming `machineID`: that Mac is listed
    /// once, under its machine ID, whatever it was keyed by before (its node,
    /// while tagged) and whichever node it used last time.
    public static func adopt(_ known: inout [String: RemoteMachine], machineID: String, node: String, name: String) {
        let placeholders = known.filter { $0.key != machineID && $0.value.node == node }.map(\.key)
        var machine = known[machineID] ?? placeholders.first.flatMap { known[$0] }
        for key in placeholders { known[key] = nil }
        if let existing = machine, existing.stableID != machineID {
            machine = RemoteMachine(stableID: machineID, name: existing.name, state: existing.state,
                                    lastSeen: existing.lastSeen, workspace: existing.workspace,
                                    address: existing.address, node: node)
        }
        var adopted = machine ?? RemoteMachine(stableID: machineID, name: name, state: .connecting,
                                               lastSeen: nil, workspace: nil, node: node)
        adopted.node = node
        adopted.name = name
        known[machineID] = adopted
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
