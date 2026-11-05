import Foundation

/// Who may connect to this Zetty, and which tailnet machines are worth listing
/// or dialling. Only Macs signed in to Tailscale as the same user, untagged.
public enum PeerAdmission: Equatable, Sendable {
    case admit
    case refuse(Refusal)

    public enum Refusal: Equatable, Sendable { case tagged, otherUser, notMac, unknownNode, thisMac }

    /// Checked in this order. This Mac itself comes first: any local macOS
    /// user can reach its tailnet address, so admitting it would let another
    /// user here open this user's panes. It used to be refused only because
    /// `whois` of this Mac's own address reports no OS, which no Tailscale
    /// release promises. Tags come before the user because a tagged node
    /// belongs to the tag, not to a person, so "another user" would mislead.
    public static func decide(me: TailscaleNode, peer: TailscaleNode?) -> PeerAdmission {
        guard let peer else { return .refuse(.unknownNode) }
        if peer.stableID == me.stableID || !Set(peer.addresses).isDisjoint(with: me.addresses) {
            return .refuse(.thisMac)
        }
        if !peer.tags.isEmpty { return .refuse(.tagged) }
        if peer.userID != me.userID { return .refuse(.otherUser) }
        if peer.os != "macOS" { return .refuse(.notMac) }
        return .admit
    }

    /// Online peers this Mac should connect to. Never this Mac itself.
    public static func candidates(in status: TailscaleStatus) -> [TailscaleNode] {
        guard let me = status.me else { return [] }
        return others(of: me, in: status).filter { $0.online && decide(me: me, peer: $0) == .admit }
    }

    /// Macs worth a sidebar group, online or not: admitted ones, plus tagged
    /// ones so the sidebar can say why they can't join. Other people's Macs
    /// are left out and only counted (`otherUsersMacs`).
    public static func listable(in status: TailscaleStatus) -> [TailscaleNode] {
        guard let me = status.me else { return [] }
        return others(of: me, in: status).filter {
            guard $0.os == "macOS" else { return false }
            let verdict = decide(me: me, peer: $0)
            return verdict == .admit || verdict == .refuse(.tagged)
        }
    }

    /// Untagged Macs signed in as someone else, for Settings' status line.
    public static func otherUsersMacs(in status: TailscaleStatus) -> Int {
        guard let me = status.me else { return 0 }
        return others(of: me, in: status).filter {
            $0.os == "macOS" && decide(me: me, peer: $0) == .refuse(.otherUser)
        }.count
    }

    private static func others(of me: TailscaleNode, in status: TailscaleStatus) -> [TailscaleNode] {
        status.peers.filter { $0.stableID != me.stableID }
    }
}

extension PeerAdmission.Refusal {
    /// Plain words for someone who doesn't know Tailscale well.
    public func message(machine: String) -> String {
        switch self {
        case .tagged: "\(machine) is tagged in Tailscale, so it can't join"
        case .otherUser: "\(machine) isn't signed in to Tailscale as you"
        case .notMac: "\(machine) isn't a Mac"
        case .unknownNode: "Tailscale doesn't know \(machine)"
        case .thisMac: "\(machine) is this Mac, which doesn't connect to itself"
        }
    }
}
