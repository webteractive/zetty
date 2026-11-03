import Foundation
import Testing
@testable import ZettyCore

private func node(_ id: String, user: Int64, os: String = "macOS", tags: [String] = [],
                  online: Bool = true) -> TailscaleNode {
    TailscaleNode(stableID: id, hostName: id, dnsName: "\(id).tail.ts.net", os: os, userID: user,
                  tags: tags, addresses: ["100.64.0.1"], online: online, lastSeen: nil)
}

@Test func admitsOnlySameUserUntaggedMacs() {
    let me = node("me", user: 111)
    #expect(PeerAdmission.decide(me: me, peer: node("mini", user: 111)) == .admit)
    #expect(PeerAdmission.decide(me: me, peer: node("box", user: 111, tags: ["tag:server"])) == .refuse(.tagged))
    #expect(PeerAdmission.decide(me: me, peer: node("kin", user: 222)) == .refuse(.otherUser))
    #expect(PeerAdmission.decide(me: me, peer: node("pi", user: 111, os: "linux")) == .refuse(.notMac))
    #expect(PeerAdmission.decide(me: me, peer: nil) == .refuse(.unknownNode))
}

@Test func taggedBeatsOtherUserBecauseTaggedNodesHaveNoRealUser() {
    #expect(PeerAdmission.decide(me: node("me", user: 111),
                                 peer: node("box", user: 999, tags: ["tag:x"])) == .refuse(.tagged))
}

@Test func osMatchIsExact() {
    #expect(PeerAdmission.decide(me: node("me", user: 111), peer: node("x", user: 111, os: "macos"))
            == .refuse(.notMac))
}

@Test func candidatesAreOnlineSameUserMacsAndNeverSelf() throws {
    let s = try #require(TailscaleStatus.parse(tailscaleFixture("status")))
    #expect(PeerAdmission.candidates(in: s).map(\.hostName) == ["Mac-mini"])
    #expect(PeerAdmission.listable(in: s).map(\.hostName) == ["build-box", "Mac-mini", "Studio"])
    #expect(PeerAdmission.otherUsersMacs(in: s) == 1)
}

@Test func selfListedAsAPeerIsStillExcluded() {
    let me = node("me", user: 111)
    let status = TailscaleStatus(backend: .running, me: me, peers: [me, node("mini", user: 111)])
    #expect(PeerAdmission.candidates(in: status).map(\.stableID) == ["mini"])
    #expect(PeerAdmission.listable(in: status).map(\.stableID) == ["mini"])
}

@Test func noSelfMeansNoCandidates() {
    let status = TailscaleStatus(backend: .stopped, me: nil, peers: [node("mini", user: 111)])
    #expect(PeerAdmission.candidates(in: status).isEmpty)
    #expect(PeerAdmission.listable(in: status).isEmpty)
    #expect(PeerAdmission.otherUsersMacs(in: status) == 0)
}

@Test func refusalMessagesArePlainWords() {
    #expect(PeerAdmission.Refusal.tagged.message(machine: "Studio") == "Studio is tagged in Tailscale, so it can't join")
    #expect(PeerAdmission.Refusal.otherUser.message(machine: "Studio") == "Studio isn't signed in to Tailscale as you")
    #expect(PeerAdmission.Refusal.notMac.message(machine: "Studio") == "Studio isn't a Mac")
    #expect(PeerAdmission.Refusal.unknownNode.message(machine: "Studio") == "Tailscale doesn't know Studio")
}
