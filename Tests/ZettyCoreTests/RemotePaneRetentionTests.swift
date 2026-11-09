import Foundation
import Testing
@testable import ZettyCore

private let t0 = Date(timeIntervalSince1970: 10_000)
private let a = UUID(), b = UUID(), c = UUID()

private func pane(_ id: String) -> StatusSnapshot.Pane {
    StatusSnapshot.Pane(id: id, title: "zsh", cwd: nil, tool: nil, agentStatus: nil, isFocused: false, live: true)
}

/// Project "P-1" with panes 11111111 and 22222222, unless told otherwise.
private func mac(_ state: RemoteMachine.State = .online, address: String = "100.64.0.2",
                 hibernated: Bool = false, panes: [String] = ["11111111", "22222222"]) -> RemoteMachine {
    let workspace = StatusSnapshot(projects: [
        .init(name: "work", isActive: true, hibernated: hibernated, id: "P-1",
              tabs: hibernated ? [] : [.init(title: "main", isActive: true, panes: panes.map(pane))]),
    ])
    return RemoteMachine(stableID: "nMINI", name: "Mac mini", state: state, lastSeen: t0,
                         workspace: workspace, address: address)
}

private func kept(_ project: String = "P-1", leftAt: Date = t0,
                  surfaces: [String: UUID] = ["11111111": a, "22222222": b]) -> RemotePaneRetention.Kept {
    .init(machine: "nMINI", project: project, address: "100.64.0.2", leftAt: leftAt, surfaces: surfaces)
}

@Test func aProjectLeftRecentlyKeepsItsPanes() {
    let result = RemotePaneRetention.prune([kept()], machines: [mac()], now: t0.addingTimeInterval(60))
    #expect(result.kept == [kept()])
    #expect(result.free.isEmpty)
}

@Test func keptPanesGoAfterThirtyMinutes() {
    let now = t0.addingTimeInterval(RemotePaneRetention.keepFor)
    let result = RemotePaneRetention.prune([kept()], machines: [mac()], now: now)
    #expect(result.kept.isEmpty)
    #expect(result.free == [a, b])
}

@Test func keptPanesGoWhenTheirMacCantBeReachedThere() {
    let cases: [[RemoteMachine]] = [
        [], [mac(.offline)], [mac(.connecting)], [mac(.needsUpdate(theirs: 9))],
        [mac(address: "100.64.0.9")], // the relays dialled the old address
    ]
    for machines in cases {
        let result = RemotePaneRetention.prune([kept()], machines: machines, now: t0)
        #expect(result.kept.isEmpty)
        #expect(result.free == [a, b])
    }
}

@Test func keptPanesGoWhenTheProjectClosesOrHibernatesThere() {
    for machine in [mac(hibernated: true), mac(panes: [])] {
        #expect(RemotePaneRetention.prune([kept()], machines: [machine], now: t0).free == [a, b])
    }
    #expect(RemotePaneRetention.prune([kept("P-gone")], machines: [mac()], now: t0).free == [a, b])
}

@Test func aPaneClosedThereGoesOnItsOwn() {
    let result = RemotePaneRetention.prune([kept()], machines: [mac(panes: ["11111111"])], now: t0)
    #expect(result.kept.map(\.surfaces) == [["11111111": a]])
    #expect(result.free == [b])
}

@Test func pastTheCapTheProjectsLeftLongestAgoGoWhole() {
    let older = kept(leftAt: t0, surfaces: ["11111111": a])
    let newer = kept(leftAt: t0.addingTimeInterval(10), surfaces: ["22222222": b])
    let result = RemotePaneRetention.prune([older, newer], machines: [mac()], now: t0.addingTimeInterval(20),
                                           maxSurfaces: 1)
    #expect(result.kept == [newer])
    #expect(result.free == [a])
}

@Test func aSmallerOlderProjectDoesntSlipInPastABiggerNewerOne() {
    let big = kept(leftAt: t0.addingTimeInterval(10))
    let small = kept(leftAt: t0, surfaces: ["11111111": c])
    let result = RemotePaneRetention.prune([small, big], machines: [mac()], now: t0.addingTimeInterval(20),
                                           maxSurfaces: 1)
    #expect(result.kept.isEmpty)
    #expect(result.free == [a, b, c])
}
