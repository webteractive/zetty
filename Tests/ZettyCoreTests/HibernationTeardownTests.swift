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
