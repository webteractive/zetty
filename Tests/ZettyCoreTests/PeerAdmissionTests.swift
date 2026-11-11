import Foundation
import Testing
@testable import ZettyCore

/// A Zetty node (`zetty-<id>`) unless `host` says otherwise.
private func node(_ id: String, user: Int64, host: String? = nil, os: String = "macOS", tags: [String] = [],
                  online: Bool = true) -> TailscaleNode {
    let octets = id.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    let own = "100.64.\(octets >> 8 & 0xFF).\(octets & 0xFF)"
    return TailscaleNode(stableID: id, hostName: host ?? "zetty-\(id)", dnsName: "\(id).tail.ts.net", os: os,
                         userID: user, tags: tags, addresses: [own], online: online, lastSeen: nil)
}

@Test func admitsOnlySameUserUntaggedZettyMacs() {
    let me = node("me", user: 111)
    #expect(PeerAdmission.decide(me: me, peer: node("mini", user: 111)) == .admit)
    #expect(PeerAdmission.decide(me: me, peer: node("box", user: 111, tags: ["tag:server"])) == .refuse(.tagged))
    #expect(PeerAdmission.decide(me: me, peer: node("kin", user: 222)) == .refuse(.otherUser))
    #expect(PeerAdmission.decide(me: me, peer: node("pi", user: 111, os: "linux")) == .refuse(.notMac))
    #expect(PeerAdmission.decide(me: me, peer: nil) == .refuse(.unknownNode))
}

@Test func macsOwnTailscaleDeviceIsRefused() {
    // The Mac's own Tailscale device carries everything on that Mac: other
    // macOS accounts, containers, VMs. Only Zetty's own node may connect.
    let me = node("me", user: 111)
    let laptop = node("laptop", user: 111, host: "WebteractiveGlen")
    #expect(PeerAdmission.decide(me: me, peer: laptop) == .refuse(.notZetty))
    #expect(PeerAdmission.decide(me: me, peer: node("x", user: 111, host: "zettymini")) == .refuse(.notZetty))
    #expect(PeerAdmission.decide(me: me, peer: node("y", user: 111, host: "Zetty-Mini")) == .admit)
}

@Test func anotherZettyOnThisMacIsAdmitted() {
    // A second Zetty here (the isolated test app) is its own node with its
    // own sign-in, so it is just another of this user's Zettys.
    #expect(PeerAdmission.decide(me: node("me", user: 1), peer: node("test-copy", user: 1)) == .admit)
}

@Test func refusalOrder() {
    let me = node("me", user: 111)
    #expect(PeerAdmission.decide(me: me, peer: node("box", user: 999, host: "box", tags: ["tag:x"])) == .refuse(.tagged))
    #expect(PeerAdmission.decide(me: me, peer: node("kin", user: 222, host: "kin")) == .refuse(.otherUser))
    #expect(PeerAdmission.decide(me: me, peer: node("pi", user: 111, host: "pi", os: "linux")) == .refuse(.notZetty))
    #expect(PeerAdmission.decide(me: me, peer: node("me", user: 111, os: "")) == .refuse(.thisNode))
}

@Test func osMatchIsExact() {
    #expect(PeerAdmission.decide(me: node("me", user: 111), peer: node("x", user: 111, os: "macos"))
            == .refuse(.notMac))
}

@Test func candidatesAreOnlineSameUserZettysAndNeverSelf() {
    let me = node("me", user: 111)
    let status = TailscaleStatus(backend: .running, me: me, peers: [
        me,
        node("mini", user: 111),
        node("asleep", user: 111, online: false),
        node("laptop", user: 111, host: "WebteractiveGlen"),
        node("box", user: 111, tags: ["tag:server"]),
        node("kin", user: 222),
        node("kin-mac", user: 222, host: "Kins-Mac"),
    ])
    #expect(PeerAdmission.candidates(in: status).map(\.stableID) == ["mini"])
    #expect(PeerAdmission.listable(in: status).map(\.stableID) == ["mini", "asleep", "box"])
    #expect(PeerAdmission.otherUsersMacs(in: status) == 2)
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
    #expect(PeerAdmission.Refusal.thisNode.message(machine: "Studio") == "Studio is this Zetty")
    #expect(PeerAdmission.Refusal.notZetty.message(machine: "Studio") == "Studio isn't a Zetty")
}
