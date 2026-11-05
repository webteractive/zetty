import Foundation
import Testing
@testable import ZettyCore

/// Each id gets its own address, so only `addresses:` makes two nodes share one.
private func node(_ id: String, user: Int64, os: String = "macOS", tags: [String] = [],
                  online: Bool = true, addresses: [String]? = nil) -> TailscaleNode {
    let octets = id.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    let own = "100.64.\(octets >> 8 & 0xFF).\(octets & 0xFF)"
    return TailscaleNode(stableID: id, hostName: id, dnsName: "\(id).tail.ts.net", os: os, userID: user,
                         tags: tags, addresses: addresses ?? [own], online: online, lastSeen: nil)
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

@Test func thisMacsOwnAddressIsNeverAdmitted() {
    // Any local user can reach the tailnet address, while only this user can
    // reach the control socket, so a self-admit would let another macOS user
    // on this Mac open this user's panes. It is refused by identity, not by
    // `whois` of this Mac happening to report no OS (Tailscale 1.104 does).
    let me = node("self", user: 1)
    #expect(PeerAdmission.decide(me: me, peer: node("self", user: 1, os: "")) == .refuse(.thisMac))
    #expect(PeerAdmission.decide(me: me, peer: node("self", user: 1)) == .refuse(.thisMac))
    // Another node id on one of this Mac's addresses is still this Mac.
    let shared = node("other-id", user: 1, addresses: me.addresses)
    #expect(PeerAdmission.decide(me: me, peer: shared) == .refuse(.thisMac))
}
