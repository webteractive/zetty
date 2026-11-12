import Testing
import Foundation
@testable import ZettyCore

// The sidebar's Active section: every agent session that is working or needs
// you, on this Mac and the other Macs shown (spec 2026-11-06-sidebar-active).

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

private func local(_ id: String, _ status: AgentStatus, project: String = "zetty",
                   tool: AgentKind? = .claude, tab: String = "main") -> ActiveSession {
    ActiveSession(id: id, status: status, machine: nil, project: project, tool: tool, tabTitle: tab,
                  target: .local(projectID: UUID(), tabIndex: 0, surfaceID: UUID()))
}

@Test func onlyWorkingAndNeedsAttentionSessionsAreActive() {
    let active = ActiveSessions()
    let rows = active.update([
        local("a", .running), local("b", .needsAttention, project: "api"),
        local("c", .idle, project: "web"), local("d", .errored, project: "ops"),
    ], now: t0)
    #expect(Set(rows.map(\.id)) == ["a", "b"])
}

@Test func needsAttentionComesFirstThenTheOrderRowsArrived() {
    let active = ActiveSessions()
    _ = active.update([local("old", .running, project: "one")], now: t0)
    _ = active.update([local("old", .running, project: "one"), local("new", .running, project: "two")],
                      now: t0 + 1)
    let rows = active.update([
        local("old", .running, project: "one"), local("new", .running, project: "two"),
        local("asks", .needsAttention, project: "three"),
    ], now: t0 + 2)
    #expect(rows.map(\.id) == ["asks", "old", "new"])
}

@Test func aSessionThatFlipsKeepsItsArrivalTime() {
    let active = ActiveSessions()
    _ = active.update([local("a", .running, project: "one")], now: t0)
    _ = active.update([local("a", .running, project: "one"), local("b", .running, project: "two")], now: t0 + 1)
    // b asks, then goes back to work: it rejoins working rows by its first arrival,
    // so it stays after a.
    _ = active.update([local("a", .running, project: "one"), local("b", .needsAttention, project: "two")],
                      now: t0 + 2)
    let rows = active.update([local("a", .running, project: "one"), local("b", .running, project: "two")],
                             now: t0 + 3)
    #expect(rows.map(\.id) == ["a", "b"])
}

@Test func aSessionThatStopsLeavesAtOnce() {
    let active = ActiveSessions()
    _ = active.update([local("a", .running), local("b", .running)], now: t0)
    #expect(active.update([local("a", .idle), local("b", .running)], now: t0 + 1).map(\.id) == ["b"])
    #expect(active.update([local("b", .running)], now: t0 + 2).map(\.id) == ["b"])   // pane gone
    #expect(active.update([], now: t0 + 3).isEmpty)
}

@Test func aSessionBusyAgainRejoinsAtTheBottomOfItsGroup() {
    let active = ActiveSessions()
    _ = active.update([local("a", .running), local("b", .running)], now: t0)
    _ = active.update([local("a", .idle), local("b", .running)], now: t0 + 1)
    let rows = active.update([local("a", .running), local("b", .running)], now: t0 + 2)
    #expect(rows.map(\.id) == ["b", "a"])
}

@Test func labelsNameTheProjectAndToolAndTheTabWhenAProjectHasSeveral() {
    let active = ActiveSessions()
    let rows = active.update([
        local("a", .running, project: "zetty", tab: "fix"),
        local("b", .running, project: "zetty", tool: .codex, tab: "docs"),
        local("c", .running, project: "api"),
        local("d", .running, project: "web", tool: nil),
    ], now: t0)
    #expect(rows.map(\.label) == ["zetty · Claude · fix", "zetty · Codex · docs", "api · Claude", "web"])
}

@Test func remoteSessionsComeFromOnlineSnapshotsWithTheMacsName() {
    func pane(_ id: String, _ status: String?, tool: String? = "claude") -> StatusSnapshot.Pane {
        StatusSnapshot.Pane(id: id, title: nil, cwd: nil, tool: tool, agentStatus: status,
                            isFocused: false, live: true)
    }
    let snapshot = StatusSnapshot(projects: [
        StatusSnapshot.Project(name: "devops", isActive: false, hibernated: false, id: "P1", tabs: [
            StatusSnapshot.Tab(title: "one", isActive: true, panes: [pane("aa", "running"), pane("bb", "idle")]),
            StatusSnapshot.Tab(title: "two", isActive: false, panes: [pane("cc", "needsAttention", tool: nil)]),
        ]),
        StatusSnapshot.Project(name: "asleep", isActive: false, hibernated: true, id: "P2", tabs: [
            StatusSnapshot.Tab(title: "z", isActive: true, panes: [pane("dd", "running")]),
        ]),
    ])
    let sessions = ActiveSessions.remoteSessions(machineID: "node1", machineName: "WebteractiveGlen",
                                                 snapshot: snapshot)
    #expect(sessions.map(\.id) == ["node1/aa", "node1/bb", "node1/cc"])
    #expect(sessions[0].target == .remote(machineID: "node1", projectID: "P1", tabIndex: 0, paneID: "aa"))
    #expect(sessions[2].target == .remote(machineID: "node1", projectID: "P1", tabIndex: 1, paneID: "cc"))
    let rows = ActiveSessions().update(sessions, now: t0)
    #expect(rows.map(\.label) == ["WebteractiveGlen · devops · two", "WebteractiveGlen · devops · Claude · one"])
}
