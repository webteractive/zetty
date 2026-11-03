import Foundation
import Testing
@testable import ZettyCore

/// Loads a Tailscale JSON fixture. `status-stopped.json` is a real capture
/// (trimmed); the running status and whois files follow Tailscale's field names
/// and must be checked against a real capture once two Macs are on the tailnet.
func tailscaleFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                             subdirectory: "Fixtures/tailscale"))
    return try Data(contentsOf: url)
}

@Test func statusParsesSelfAndPeers() throws {
    let s = try #require(TailscaleStatus.parse(tailscaleFixture("status")))
    #expect(s.backend == .running)
    #expect(s.me?.hostName == "Glens-MacBook-Pro")
    #expect(s.me?.userID == 111)
    #expect(s.me?.stableID == "nSELF111CNTRL")
    #expect(s.peers.map(\.hostName) == ["build-box", "homelab", "Kins-MacBook", "Mac-mini", "Studio"])
    let studio = try #require(s.peers.first { $0.hostName == "Studio" })
    #expect(!studio.online)
    #expect(studio.lastSeen == ISO8601DateFormatter().date(from: "2026-11-03T06:00:00Z"))
    #expect(s.peers.first { $0.hostName == "build-box" }?.tags == ["tag:server"])
    #expect(s.peers.first { $0.hostName == "Kins-MacBook" }?.tags == [])
    #expect(s.me?.dnsName == "glens-macbook-pro.tail1234.ts.net")
}

@Test func zeroLastSeenMeansNeverSeen() throws {
    let s = try #require(TailscaleStatus.parse(tailscaleFixture("status")))
    #expect(s.peers.first { $0.hostName == "Mac-mini" }?.lastSeen == nil)
    #expect(s.peers.first { $0.hostName == "homelab" }?.lastSeen == nil)
}

@Test func stoppedStatusHasNoSelfAndNoPeers() throws {
    // A real stopped capture still carries a Self, with an empty ID.
    let s = try #require(TailscaleStatus.parse(tailscaleFixture("status-stopped")))
    #expect(s.backend == .stopped)
    #expect(s.me == nil)
    #expect(s.peers.isEmpty)
}

@Test func backendStatesMapToPlainCases() throws {
    func backend(_ value: String) -> TailscaleStatus.Backend? {
        TailscaleStatus.parse(Data(#"{"BackendState":"\#(value)"}"#.utf8))?.backend
    }
    #expect(backend("NeedsLogin") == .needsLogin)
    #expect(backend("Starting") == .other("Starting"))
}

@Test func whoisParsesNodeAndStripsPrefixLengths() throws {
    let n = try #require(TailscaleWhois.parse(tailscaleFixture("whois-mini")))
    #expect(n.stableID == "nMINI111CNTRL")
    #expect(n.hostName == "Mac-mini")
    #expect(n.os == "macOS")
    #expect(n.userID == 111)
    #expect(n.tags.isEmpty)
    #expect(n.addresses == ["100.101.1.2", "fd7a:115c:a1e0::2"])
    #expect(n.online)
}

@Test func whoisKeepsTags() throws {
    let n = try #require(TailscaleWhois.parse(tailscaleFixture("whois-tagged")))
    #expect(n.tags == ["tag:server"])
}

@Test func garbageIsNotAStatus() {
    #expect(TailscaleStatus.parse(Data("nope".utf8)) == nil)
    #expect(TailscaleWhois.parse(Data("{}".utf8)) == nil)
}
