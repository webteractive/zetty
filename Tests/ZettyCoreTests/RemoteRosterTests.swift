import Foundation
import Testing
@testable import ZettyCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func zetty(_ id: String, user: Int64 = 1, host: String? = nil, tags: [String] = [],
                   online: Bool = true, seen: Date? = nil) -> TailscaleNode {
    TailscaleNode(stableID: id, hostName: host ?? "zetty-\(id)", dnsName: "\(id).ts.net", os: "macOS",
                  userID: user, tags: tags, addresses: ["100.64.0.\(id.count)"], online: online, lastSeen: seen)
}

private func status(_ peers: [TailscaleNode]) -> TailscaleStatus {
    TailscaleStatus(backend: .running, me: zetty("me"), peers: peers)
}

private func known(_ id: String, _ name: String, _ state: RemoteMachine.State, seen: Date? = nil,
                   node: String? = nil) -> RemoteMachine {
    var machine = RemoteMachine(stableID: id, name: name, state: state, lastSeen: seen, workspace: nil)
    machine.node = node
    return machine
}

// MARK: - A Mac becomes a group once it answers

@Test func rosterAddsNoMacThatHasNotAnswered() {
    let roster = RemoteRoster.reconcile([:], with: status([zetty("nMINI"), zetty("nBOX", tags: ["tag:server"])]))
    // The mini never said hello, so it isn't a group. Only the tagged Zetty
    // is listed, keyed by its node, to explain itself.
    #expect(Array(roster.keys) == ["nBOX"])
    #expect(roster["nBOX"]?.state == .refused("zetty-nBOX is tagged in Tailscale, so it can't join"))
}

@Test func rosterKeepsMacsThatAnsweredBefore() {
    let tailscaleSeen = Date(timeIntervalSince1970: 1_700_000_000)
    let mini = known("M-mini", "Mac mini", .online, seen: now, node: "nMINI")
    let studio = known("M-studio", "Studio", .offline, node: "nSTUDIO")
    let roster = RemoteRoster.reconcile(["M-mini": mini, "M-studio": studio],
                                        with: status([zetty("nMINI"), zetty("nSTUDIO", online: false, seen: tailscaleSeen)]))
    #expect(roster["M-mini"] == mini)
    // Never connected this run: Tailscale's LastSeen fills the gap.
    #expect(roster["M-studio"]?.lastSeen == tailscaleSeen)
}

@Test func rosterClearsARefusalThatNoLongerApplies() {
    let mini = known("M-mini", "Mac mini", .refused("Mac mini is tagged in Tailscale, so it can't join"), node: "nMINI")
    let roster = RemoteRoster.reconcile(["M-mini": mini], with: status([zetty("nMINI")]))
    #expect(roster["M-mini"]?.state == .offline)
}

@Test func machineWhoseNodeLeftIsDropped() {
    // An ephemeral test copy that ended, or a device removed in the admin
    // console: gone from the tailnet, so gone from the sidebar.
    let gone = known("M-test", "Test copy", .offline, node: "nTEST")
    let stays = known("M-mini", "Mac mini", .offline, node: "nMINI")
    let roster = RemoteRoster.reconcile(["M-test": gone, "M-mini": stays], with: status([zetty("nMINI")]))
    #expect(Array(roster.keys) == ["M-mini"])
}

@Test func noNodeMeansNothingIsDropped() {
    let mini = known("M-mini", "Mac mini", .offline, node: "nMINI")
    let stopped = TailscaleStatus(backend: .stopped, me: nil, peers: [])
    #expect(RemoteRoster.reconcile(["M-mini": mini], with: stopped) == ["M-mini": mini])
}

@Test func reEnrolledPeerStaysOneMachine() {
    // Signed out and in again: a new node, the same machine ID.
    var roster = ["M-mini": known("M-mini", "Mac mini", .offline, node: "nOLD")]
    RemoteRoster.adopt(&roster, machineID: "M-mini", node: "nNEW", name: "Mac mini")
    #expect(Array(roster.keys) == ["M-mini"])
    #expect(roster["M-mini"]?.node == "nNEW")
}

@Test func adoptingReplacesTheNodeKeyedPlaceholder() {
    // A tagged Zetty was listed by node; once untagged it says hello.
    var roster = ["nBOX": known("nBOX", "zetty-box", .refused("tagged"), node: "nBOX")]
    RemoteRoster.adopt(&roster, machineID: "M-box", node: "nBOX", name: "Build box")
    #expect(Array(roster.keys) == ["M-box"])
    #expect(roster["M-box"]?.name == "Build box")
    #expect(roster["M-box"]?.stableID == "M-box")
}

// MARK: - Finding 2: "seen N ago" counts from the drop

@Test func disconnectingAnOnlineMacStampsWhenItWasLastSeen() {
    var mini = known("n", "Mac mini", .online, seen: now.addingTimeInterval(-7200))
    mini.markDisconnected(at: now)
    #expect(mini.state == .offline)
    #expect(mini.lastSeen == now)
}

@Test func disconnectingKeepsAReasonAndAnOlderSighting() {
    var refused = known("n", "Studio", .refused("Studio isn't a Mac"), seen: nil)
    refused.markDisconnected(at: now)
    #expect(refused.state == .refused("Studio isn't a Mac"))
    #expect(refused.lastSeen == nil)
    var connecting = known("n", "Studio", .connecting, seen: now.addingTimeInterval(-60))
    connecting.markDisconnected(at: now)
    #expect(connecting.state == .offline)
    #expect(connecting.lastSeen == now.addingTimeInterval(-60))
}

// MARK: - Finding 1: at most one snapshot per interval

@Test func throttleSendsTheFirstSnapshotAtOnceThenDefersTheRest() {
    var throttle = SnapshotThrottle(interval: 1)
    #expect(throttle.offer(at: now) == .sendNow)
    #expect(throttle.offer(at: now.addingTimeInterval(0.25)) == .sendAfter(0.75))
    #expect(throttle.offer(at: now.addingTimeInterval(0.5)) == .alreadyPending)
    throttle.sent(at: now.addingTimeInterval(1))
    #expect(throttle.offer(at: now.addingTimeInterval(1.5)) == .sendAfter(0.5))
    throttle.sent(at: now.addingTimeInterval(2))
    #expect(throttle.offer(at: now.addingTimeInterval(4)) == .sendNow)
}
