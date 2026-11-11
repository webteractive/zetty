import Foundation
import Testing
@testable import ZettyCore

private func event(_ json: String) -> Data { Data(json.utf8) }

private let running = TailscaleStatus(
    backend: .running,
    me: TailscaleNode(stableID: "nME", hostName: "zetty-mini", dnsName: "zetty-mini.ts.net", os: "macOS",
                      userID: 1, tags: [], addresses: ["100.64.0.1"], online: true, lastSeen: nil),
    peers: [])

@Test func needsLoginCarriesTheURL() {
    let state = TailnetState.from(event: event(#"{"state":"NeedsLogin","authURL":"https://login.tailscale.com/a/x"}"#),
                                  status: nil)
    #expect(state == .needsLogin(URL(string: "https://login.tailscale.com/a/x")))
    #expect(TailnetState.from(event: event(#"{"state":"NeedsLogin"}"#), status: nil) == .needsLogin(nil))
}

@Test func machineAuthIsWaitingForApproval() {
    #expect(TailnetState.from(event: event(#"{"state":"NeedsMachineAuth"}"#), status: nil) == .needsApproval)
}

@Test func runningNeedsANodeOfItsOwn() {
    #expect(TailnetState.from(event: event(#"{"state":"Running"}"#), status: running) == .running(running))
    #expect(TailnetState.from(event: event(#"{"state":"Running"}"#), status: nil) == .starting)
}

@Test func startingAndUnknownStatesAreStarting() {
    #expect(TailnetState.from(event: event(#"{"state":"Starting"}"#), status: nil) == .starting)
    #expect(TailnetState.from(event: event(#"{"state":"NoState"}"#), status: nil) == .starting)
    #expect(TailnetState.from(event: event("garbage"), status: nil) == .starting)
}

@Test func stoppedIsOff() {
    #expect(TailnetState.from(event: event(#"{"state":"Stopped"}"#), status: nil) == .off)
}

@Test func onlyARealLoginURLIsKept() {
    // The URL is opened in the browser, so nothing but https to Tailscale.
    #expect(TailnetState.from(event: event(#"{"state":"NeedsLogin","authURL":"file:///etc/passwd"}"#), status: nil)
            == .needsLogin(nil))
    #expect(TailnetState.from(event: event(#"{"state":"NeedsLogin","authURL":"https://evil.example/a"}"#), status: nil)
            == .needsLogin(nil))
}

@Test func aStaleErrorDoesNotOutliveARunningNode() {
    // A one-off control error stays in the last event; a status that reads
    // Running with a node of its own wins over it.
    let runningStatus = TailscaleStatus(backend: .running, me: running.me, peers: [])
    #expect(TailnetState.from(event: event(#"{"state":"Running","error":"blip"}"#), status: runningStatus)
            == .running(runningStatus))
}

@Test func anErrorStillShowsWhenTheNodeIsNotRunning() {
    let stopped = TailscaleStatus(backend: .stopped, me: nil, peers: [])
    #expect(TailnetState.from(event: event(#"{"state":"Stopped","error":"key expired"}"#), status: stopped)
            == .failed("key expired"))
}

@Test func onlyAPageTailscaleAsksToOpenIsOpened() {
    // Sign In opens the page Tailscale sends after it is asked (a fresh one,
    // or one it knows is still valid), never the URL cached in the state.
    let fresh = event(#"{"state":"NeedsLogin","authURL":"https://login.tailscale.com/a/new","browse":true}"#)
    #expect(TailnetState.pageToOpen(event: fresh) == URL(string: "https://login.tailscale.com/a/new"))
    let cached = event(#"{"state":"NeedsLogin","authURL":"https://login.tailscale.com/a/old"}"#)
    #expect(TailnetState.pageToOpen(event: cached) == nil)
    let foreign = event(#"{"state":"NeedsLogin","authURL":"https://example.com/a","browse":true}"#)
    #expect(TailnetState.pageToOpen(event: foreign) == nil)
    #expect(TailnetState.pageToOpen(event: event("not json")) == nil)
}
