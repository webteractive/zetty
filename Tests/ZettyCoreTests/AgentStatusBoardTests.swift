import Testing
import Foundation
@testable import ZettyCore

private let pane = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!

private func report(_ state: AgentReport.State, at: TimeInterval, from source: AgentReport.Source = .hook,
                    agent: AgentKind = .claude, session: AgentSession? = nil) -> AgentReport {
    AgentReport(source: source, agent: agent, state: state, at: at, session: session)
}

@Test func newerReportWins() {
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 10), to: pane, replay: false, now: 10)
    let result = board.apply(report(.idle, at: 11), to: pane, replay: false, now: 11)
    #expect(result.accepted)
    #expect(board.state(for: pane).status == .idle)
}

@Test func olderReportIsIgnored() {
    let board = AgentStatusBoard()
    board.apply(report(.idle, at: 11, from: .mod), to: pane, replay: false, now: 11)
    let late = board.apply(report(.running, at: 10), to: pane, replay: false, now: 12)
    #expect(late.accepted == false)
    #expect(board.state(for: pane).status == .idle)
}

@Test func tieGoesToTheMod() {
    let hookFirst = AgentStatusBoard()
    hookFirst.apply(report(.running, at: 10, from: .hook), to: pane, replay: false, now: 10)
    #expect(hookFirst.apply(report(.idle, at: 10, from: .mod), to: pane, replay: false, now: 10).accepted)
    #expect(hookFirst.state(for: pane).status == .idle)

    let modFirst = AgentStatusBoard()
    modFirst.apply(report(.idle, at: 10, from: .mod), to: pane, replay: false, now: 10)
    #expect(modFirst.apply(report(.running, at: 10, from: .hook), to: pane, replay: false, now: 10).accepted == false)
    #expect(modFirst.state(for: pane).status == .idle)
}

@Test func sameMomentFromHookAndModChangesTheDotOnce() {
    // Either arrival order: one raise, one dot change.
    for order in [[AgentReport.Source.mod, .hook], [.hook, .mod]] {
        let board = AgentStatusBoard()
        board.apply(report(.running, at: 5), to: pane, replay: false, now: 5)
        let reports = order.map { report(.needsAttention, at: $0 == .mod ? 10.000 : 10.004, from: $0) }
        let results = reports.map { board.apply($0, to: pane, replay: false, now: 10.01) }
        #expect(results.filter(\.raisedAttention).count == 1)
        #expect(results.filter { $0.accepted && $0.previous != $0.state.status }.count == 1)
        #expect(board.state(for: pane).status == .needsAttention)
    }
}

@Test func repeatPromptOutsideWindowRaisesAgain() {
    let board = AgentStatusBoard()
    #expect(board.apply(report(.needsAttention, at: 10), to: pane, replay: false, now: 10).raisedAttention)
    board.apply(report(.running, at: 11), to: pane, replay: false, now: 11)
    #expect(board.apply(report(.needsAttention, at: 15), to: pane, replay: false, now: 15).raisedAttention)

    let quick = AgentStatusBoard()
    #expect(quick.apply(report(.needsAttention, at: 10), to: pane, replay: false, now: 10).raisedAttention)
    #expect(quick.apply(report(.needsAttention, at: 11.5), to: pane, replay: false, now: 11.5).raisedAttention == false)
}

@Test func replayAgesOutOldYellow() {
    let now: TimeInterval = 100_000
    let old = AgentStatusBoard()
    let aged = old.apply(report(.needsAttention, at: now - 901), to: pane, replay: true, now: now)
    #expect(old.state(for: pane).status == .idle)
    #expect(aged.raisedAttention == false)

    let fresh = AgentStatusBoard()
    let kept = fresh.apply(report(.needsAttention, at: now - 60), to: pane, replay: true, now: now)
    #expect(fresh.state(for: pane).status == .needsAttention)
    #expect(kept.raisedAttention == false)
}

@Test func replayAgesOutOldRunning() {
    let now: TimeInterval = 100_000
    let board = AgentStatusBoard()
    board.apply(report(.running, at: now - 901), to: pane, replay: true, now: now)
    #expect(board.state(for: pane).status == .idle)
}

@Test func runningThenIdleIsFinished() {
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 10), to: pane, replay: false, now: 10)
    #expect(board.apply(report(.idle, at: 20), to: pane, replay: false, now: 20).finished)
    #expect(board.apply(report(.idle, at: 21), to: pane, replay: false, now: 21).finished == false)

    let signalled = AgentStatusBoard()
    signalled.apply(report(.running, at: 10), to: pane, replay: false, now: 10)
    #expect(signalled.noteFinished(pane: pane, at: 19))
    #expect(signalled.apply(report(.idle, at: 20), to: pane, replay: false, now: 20).finished == false)
    #expect(signalled.noteFinished(pane: pane, at: 20.5) == false)
}

@Test func replayedFinishIsNeverPosted() {
    let now: TimeInterval = 100_000
    let board = AgentStatusBoard()
    board.apply(report(.running, at: now - 30), to: pane, replay: true, now: now)
    #expect(board.apply(report(.idle, at: now - 20), to: pane, replay: true, now: now).finished == false)
}

@Test func endedClearsPresence() {
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 10, session: AgentSession(id: "s1", cwd: "/p")), to: pane, replay: false, now: 10)
    #expect(board.state(for: pane).session?.id == "s1")
    board.apply(report(.ended, at: 11), to: pane, replay: false, now: 11)
    #expect(board.state(for: pane) == AgentState())
}

@Test func sessionIsKeptAcrossReportsWithoutOne() {
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 10, session: AgentSession(id: "s1", cwd: "/p")), to: pane, replay: false, now: 10)
    board.apply(report(.idle, at: 11), to: pane, replay: false, now: 11)
    #expect(board.state(for: pane) == AgentState(kind: .claude, status: .idle, session: AgentSession(id: "s1", cwd: "/p")))
}

@Test func twoEmptyProbesEndTheAgent() {
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 10), to: pane, replay: false, now: 10)
    board.observeForeground("", pane: pane, now: 13)
    #expect(board.state(for: pane).status == .running)
    let ended = board.observeForeground("", pane: pane, now: 16)
    #expect(board.state(for: pane) == AgentState())
    #expect(ended.previous == .running)
}

@Test func probeEndOutranksTheReportsBeforeIt() {
    // A mod snapshot left behind by a killed agent is re-read every poll; it
    // must not bring the dot back once the probe has ended it.
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 10, from: .mod), to: pane, replay: false, now: 10)
    board.observeForeground("", pane: pane, now: 13)
    board.observeForeground("", pane: pane, now: 16)
    #expect(board.apply(report(.running, at: 10, from: .mod), to: pane, replay: false, now: 17).accepted == false)
    #expect(board.state(for: pane) == AgentState())
}

@Test func anAgentForegroundResetsTheMissCount() {
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 10), to: pane, replay: false, now: 10)
    board.observeForeground("", pane: pane, now: 13)
    board.observeForeground("claude", pane: pane, now: 16)
    board.observeForeground("", pane: pane, now: 19)
    #expect(board.state(for: pane).status == .running)
}

@Test func nonAgentForegroundIsNotAMiss() {
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 10), to: pane, replay: false, now: 10)
    for t in [13.0, 16, 19] { board.observeForeground("vim", pane: pane, now: t) }
    #expect(board.state(for: pane).status == .running)
}

@Test func unprobedPaneIsNeverEnded() {
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 10), to: pane, replay: false, now: 10)
    for t in [13.0, 16, 19, 22, 25] { board.observeForeground(nil, pane: pane, now: t) }
    #expect(board.state(for: pane).status == .running)
}

@Test func clearForgetsThePane() {
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 10), to: pane, replay: false, now: 10)
    board.clear(pane: pane)
    #expect(board.state(for: pane) == AgentState())
    #expect(board.apply(report(.running, at: 5), to: pane, replay: false, now: 11).accepted)
}

@Test func replayKeepsALongTurnItsSourceStillConfirms() {
    // A turn running for 20 minutes whose mod snapshot was rewritten a minute
    // ago is still running; ageing reads the last confirmation, not the start.
    let now: TimeInterval = 100_000
    let board = AgentStatusBoard()
    var long = report(.running, at: now - 1200, from: .mod)
    long.confirmedAt = now - 60
    board.apply(long, to: pane, replay: true, now: now)
    #expect(board.state(for: pane).status == .running)
}
