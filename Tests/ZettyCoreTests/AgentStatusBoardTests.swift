import Testing
import Foundation
@testable import ZettyCore

private let pane = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!

private func report(_ state: AgentReport.State, at: TimeInterval, from source: AgentReport.Source = .hook,
                    agent: AgentKind = .claude, session: AgentSession? = nil, loop: String? = nil) -> AgentReport {
    var r = AgentReport(source: source, agent: agent, state: state, at: at, session: session)
    r.loop = loop
    return r
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
    // Old, and the probe doesn't cover the pane (nil): nothing can confirm it.
    let now: TimeInterval = 100_000
    let old = AgentStatusBoard()
    let aged = old.apply(report(.needsAttention, at: now - 901), to: pane, replay: true, now: now)
    #expect(aged.raisedAttention == false)
    old.observeForeground(nil, pane: pane, now: now + 3)
    #expect(old.state(for: pane).status == .idle)

    let fresh = AgentStatusBoard()
    let kept = fresh.apply(report(.needsAttention, at: now - 60), to: pane, replay: true, now: now)
    #expect(fresh.state(for: pane).status == .needsAttention)
    #expect(kept.raisedAttention == false)
}

@Test func replayAgesOutOldRunning() {
    let now: TimeInterval = 100_000
    let board = AgentStatusBoard()
    board.apply(report(.running, at: now - 901), to: pane, replay: true, now: now)
    board.observeForeground(nil, pane: pane, now: now + 3)
    #expect(board.state(for: pane).status == .idle)
}

@Test func replayKeepsAnOldPromptTheAgentIsStillShowing() {
    // A permission prompt left for an hour, then a relaunch: the agent is
    // still in the foreground, so the decision is still pending.
    let now: TimeInterval = 100_000
    let board = AgentStatusBoard()
    board.apply(report(.needsAttention, at: now - 3600), to: pane, replay: true, now: now)
    let probed = board.observeForeground("claude", pane: pane, now: now + 3)
    #expect(probed.changedStatus == false)
    board.observeForeground(nil, pane: pane, now: now + 6)   // a later unprobed tick changes nothing
    #expect(board.state(for: pane).status == .needsAttention)
}

@Test func replayAgesALegacyLineAtOnce() {
    // A line with no time (0) is never trusted, probe or not.
    let board = AgentStatusBoard()
    board.apply(report(.needsAttention, at: 0), to: pane, replay: true, now: 100_000)
    #expect(board.state(for: pane).status == .idle)
}

// MARK: - Which loop is waiting (parallel subagents)

@Test func anotherLoopsToolCallLeavesThePromptPending() {
    let board = AgentStatusBoard()
    board.apply(report(.needsAttention, at: 10, loop: "agent-a"), to: pane, replay: false, now: 10)
    let other = board.apply(report(.running, at: 11, loop: "agent-b"), to: pane, replay: false, now: 11)
    #expect(other.changedStatus == false)
    #expect(board.state(for: pane).status == .needsAttention)
    board.apply(report(.running, at: 12, loop: "main"), to: pane, replay: false, now: 12)
    #expect(board.state(for: pane).status == .needsAttention)
}

@Test func theAskingLoopsToolCallResolvesItsPrompt() {
    let board = AgentStatusBoard()
    board.apply(report(.needsAttention, at: 10, loop: "agent-a"), to: pane, replay: false, now: 10)
    board.apply(report(.running, at: 15, loop: "agent-a"), to: pane, replay: false, now: 15)
    #expect(board.state(for: pane).status == .running)
}

@Test func twoPendingPromptsNeedBothResolved() {
    let board = AgentStatusBoard()
    board.apply(report(.needsAttention, at: 10, loop: "agent-a"), to: pane, replay: false, now: 10)
    board.apply(report(.needsAttention, at: 11, loop: "agent-b"), to: pane, replay: false, now: 11)
    board.apply(report(.running, at: 12, loop: "agent-a"), to: pane, replay: false, now: 12)
    #expect(board.state(for: pane).status == .needsAttention)
    board.apply(report(.running, at: 13, loop: "agent-b"), to: pane, replay: false, now: 13)
    #expect(board.state(for: pane).status == .running)
}

@Test func aSameMomentDuplicateStillNamesItsLoop() {
    // The mod's report and the hook's for one prompt: the older one is
    // rejected, but its loop is still the one waiting.
    let board = AgentStatusBoard()
    board.apply(report(.needsAttention, at: 10.004, from: .hook, loop: "agent-a"), to: pane, replay: false, now: 10.01)
    board.apply(report(.needsAttention, at: 10.000, from: .mod, loop: "main"), to: pane, replay: false, now: 10.01)
    board.apply(report(.running, at: 12, loop: "agent-a"), to: pane, replay: false, now: 12)
    #expect(board.state(for: pane).status == .needsAttention)
}

@Test func aReportWithoutALoopResolvesEveryPrompt() {
    // A new prompt (UserPromptSubmit), a turn's end, or an older helper
    // that names no loop: authoritative for the whole pane.
    let board = AgentStatusBoard()
    board.apply(report(.needsAttention, at: 10, loop: "agent-a"), to: pane, replay: false, now: 10)
    board.apply(report(.running, at: 11), to: pane, replay: false, now: 11)
    #expect(board.state(for: pane).status == .running)
    board.apply(report(.needsAttention, at: 20, loop: "agent-a"), to: pane, replay: false, now: 20)
    board.apply(report(.idle, at: 21, loop: "agent-b"), to: pane, replay: false, now: 21)
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

@Test func pruneForgetsPanesThatAreGone() {
    let board = AgentStatusBoard()
    let kept = UUID()
    board.apply(report(.running, at: 10), to: pane, replay: false, now: 10)
    board.apply(report(.running, at: 10), to: kept, replay: false, now: 10)
    board.prune(keeping: [kept])
    #expect(board.state(for: pane) == AgentState())
    #expect(board.state(for: kept).status == .running)
}

/// Claude clears its progress as it stops to ask. That clear is stamped when
/// it reaches Zetty, while the hook and the mod carry when the prompt
/// happened, so the clear looked newer and the prompt that followed it was
/// thrown away: no dot, no sound, a "finished" banner instead (release
/// review, 2026-11-20).
@Test func aNeedsYouJustBeforeATerminalSignalStillWins() {
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 9), to: pane, replay: false, now: 9)
    board.apply(report(.idle, at: 10.2, from: .terminal), to: pane, replay: false, now: 10.2)
    let hook = board.apply(report(.needsAttention, at: 10.0), to: pane, replay: false, now: 10.7)
    #expect(hook.accepted)
    #expect(hook.raisedAttention)
    #expect(board.state(for: pane).status == .needsAttention)
}

@Test func anOlderNeedsYouStillLosesToALaterTerminalSignal() {
    // Past the slack, the terminal signal is a real later moment.
    let board = AgentStatusBoard()
    board.apply(report(.running, at: 9), to: pane, replay: false, now: 9)
    board.apply(report(.idle, at: 12, from: .terminal), to: pane, replay: false, now: 12)
    #expect(!board.apply(report(.needsAttention, at: 10.0), to: pane, replay: false, now: 12.5).accepted)
    #expect(board.state(for: pane).status == .idle)
}

/// Reports are ordered newest-first, and a hook line's `ts` or the mod's
/// `turn.at` is whatever the file says: one stamped in the future beat every
/// real report after it, so the pane stayed yellow until its agent exited,
/// and replay restored that at every launch (native security review of
/// v0.1.62..475736a). A report counts as no newer than the moment it arrives.
@Test func aReportStampedInTheFutureDoesNotPinThePane() {
    let board = AgentStatusBoard()
    board.apply(report(.needsAttention, at: 10 + 365 * 86_400), to: pane, replay: false, now: 10)
    let next = board.apply(report(.idle, at: 15), to: pane, replay: false, now: 15)
    #expect(next.accepted)
    #expect(board.state(for: pane).status == .idle)
}
