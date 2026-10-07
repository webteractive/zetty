import Foundation
import Testing
@testable import ZettyCore

private let shell = UUID()
private let agent = UUID()
private let unprobed = UUID()
private let stale = UUID()

private func name(_ id: UUID) -> String { SessionPersistence.sessionName(for: id) }

@Test func onlyABareShellIsAskedToExit() {
    let plan = HibernationTeardown.plan(
        surfaceIDs: [shell, agent],
        foreground: [shell: "", agent: "claude"],
        agentBusy: [])
    #expect(plan.exit == [name(shell)])
    #expect(plan.all == [name(shell), name(agent)])
}

@Test func aPaneTheProbeNeverSawIsNotTypedInto() {
    // "" means the probe looked and found a shell; a missing entry means it
    // never looked. Typing `exit` into an unknown foreground could land in an
    // editor or an agent's prompt.
    let plan = HibernationTeardown.plan(
        surfaceIDs: [unprobed], foreground: [:], agentBusy: [])
    #expect(plan.exit.isEmpty)
    #expect(plan.all == [name(unprobed)])
}

@Test func aBusyAgentIsNotTypedIntoEvenIfTheProbeSaysShell() {
    let plan = HibernationTeardown.plan(
        surfaceIDs: [stale], foreground: [stale: ""], agentBusy: [stale])
    #expect(plan.exit.isEmpty)
}

@Test func exitsAreFinishedOnceNoExitingSessionIsListed() {
    let plan = HibernationTeardown.plan(
        surfaceIDs: [shell, agent], foreground: [shell: "", agent: "vim"], agentBusy: [])
    // The busy session still being listed does not hold up the wait — it is
    // killed afterwards regardless.
    #expect(plan.exitsFinished(listed: [name(agent)]))
    #expect(!plan.exitsFinished(listed: [name(shell), name(agent)]))
}

@Test func onlyStillListedSessionsAreKilled() {
    let plan = HibernationTeardown.plan(
        surfaceIDs: [shell, agent], foreground: [shell: "", agent: "vim"], agentBusy: [])
    #expect(plan.remaining(listed: [name(agent), "zetty-deadbeef"]) == [name(agent)])
    #expect(plan.remaining(listed: []).isEmpty)
}

@Test func exitInputClearsThePromptLineFirst() {
    // Ctrl-E then Ctrl-U: bash's Ctrl-U only kills BEFORE the cursor, so
    // without moving to the end first a half-typed command would survive and
    // run glued to `exit`.
    #expect(HibernationTeardown.exitInput == "\u{05}\u{15}exit\r")
}

// Codex runs its commands under a shared daemon, so ending its pane leaves
// them running; its panes are told to stop first. Which panes those are is
// read off the process table at that moment, never off the probe's map: a
// closed pane's plan carries no reading at all, and the map is up to three
// seconds behind, which once left a Codex that had just started listed as a
// shell.
@Test func codexSessionsAreFoundInTheProcessTableItself() {
    let ps = """
    500 1 500 Ss ttys001 0:00.10 700 -zsh
    501 500 501 S+ ttys001 0:01.00 9000 codex Run the tests
    600 1 600 Ss ttys002 0:00.10 700 -zsh
    601 600 601 S+ ttys002 0:01.00 9000 claude
    700 1 700 Ss+ ttys003 0:00.10 700 -zsh
    """
    let pids: [String: Int32] = ["zetty-aaaaaaaa": 500, "zetty-bbbbbbbb": 600, "zetty-cccccccc": 700]
    #expect(HibernationTeardown.codexSessions(
        among: ["zetty-aaaaaaaa", "zetty-bbbbbbbb", "zetty-cccccccc", "zetty-gone0000"],
        pids: pids, psOutput: ps) == ["zetty-aaaaaaaa"])
    #expect(HibernationTeardown.codexSessions(among: [], pids: pids, psOutput: ps).isEmpty)
}
