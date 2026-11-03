import Foundation
import Testing
@testable import ZettyCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func fixtureStatus() throws -> TailscaleStatus {
    try #require(TailscaleStatus.parse(tailscaleFixture("status")))
}

private func known(_ id: String, _ name: String, _ state: RemoteMachine.State, seen: Date? = nil) -> RemoteMachine {
    RemoteMachine(stableID: id, name: name, state: state, lastSeen: seen, workspace: nil)
}

// MARK: - Finding 3: a Mac becomes a group once it answers

@Test func rosterAddsNoMacThatHasNotAnswered() throws {
    let roster = RemoteRoster.reconcile([:], with: try fixtureStatus())
    // Mac-mini (online, admitted) and Studio (offline, admitted) never said
    // hello, so neither is a group. Only the tagged Mac is listed, to explain itself.
    #expect(Array(roster.keys) == ["nBUILD111CNTRL"])
    #expect(roster["nBUILD111CNTRL"]?.state == .refused("build-box is tagged in Tailscale, so it can't join"))
}

@Test func rosterKeepsMacsThatAnsweredBefore() throws {
    let mini = known("nMINI111CNTRL", "Mac mini", .online, seen: now)
    let studio = known("nSTUDIO11CNTRL", "Studio", .offline)
    let roster = RemoteRoster.reconcile(["nMINI111CNTRL": mini, "nSTUDIO11CNTRL": studio], with: try fixtureStatus())
    #expect(roster["nMINI111CNTRL"] == mini)
    // Never connected this run: Tailscale's LastSeen fills the gap.
    #expect(roster["nSTUDIO11CNTRL"]?.lastSeen == ISO8601DateFormatter().date(from: "2026-11-03T06:00:00Z"))
}

@Test func rosterClearsARefusalThatNoLongerApplies() throws {
    let mini = known("nMINI111CNTRL", "Mac mini", .refused("Mac mini is tagged in Tailscale, so it can't join"))
    let roster = RemoteRoster.reconcile(["nMINI111CNTRL": mini], with: try fixtureStatus())
    #expect(roster["nMINI111CNTRL"]?.state == .offline)
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
