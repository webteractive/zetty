import Foundation
import Testing
@testable import ZettyCore

/// `hibernate-after` used to exempt every project with an agent open, because
/// an idle Claude at its prompt has foreground `claude`. Those are the
/// projects holding the most memory.

private func pane(_ foreground: String?, _ status: AgentStatus? = nil,
                  box: Bool? = nil, work: Bool = false) -> HibernationEligibility.Pane {
    .init(foreground: foreground, agentStatus: status, promptBoxEmpty: box, hasBackgroundWork: work)
}

@Test func anIdleShellNeverKeepsAProjectAwake() {
    #expect(!HibernationEligibility.keepsAwake(pane("")))
    #expect(!HibernationEligibility.keepsAwake(pane(nil)))
}

@Test func anIdleAgentAtAnEmptyBoxMayBePutAway() {
    #expect(!HibernationEligibility.keepsAwake(pane("claude", .idle, box: true)))
    #expect(!HibernationEligibility.keepsAwake(pane("codex", .idle, box: true)))
}

@Test func aWorkingAgentKeepsItAwake() {
    #expect(HibernationEligibility.keepsAwake(pane("claude", .running, box: true)))
    // Reported by a hook for a pane the probe has not examined.
    #expect(HibernationEligibility.keepsAwake(pane(nil, .running)))
}

// A question replaces the prompt box with a menu, so the box does not read as
// empty while one is on screen.
@Test func anAgentWaitingOnAQuestionKeepsItAwake() {
    #expect(HibernationEligibility.keepsAwake(pane("claude", .needsAttention, box: false)))
    #expect(HibernationEligibility.keepsAwake(pane("claude", .needsAttention, box: nil)))
    #expect(HibernationEligibility.keepsAwake(pane(nil, .needsAttention)))
}

// Claude fires its notification hook after a minute at its prompt, which
// arrives as the status a permission prompt does. Read as "waiting on the
// person", it kept every idle Claude's project awake for good: the first run
// of hibernate-after put the idle shell away and left the idle agent.
@Test func claudesIdleNotificationIsNotAQuestion() {
    #expect(!HibernationEligibility.keepsAwake(pane("claude", .needsAttention, box: true)))
    #expect(HibernationEligibility.needsPromptBox(pane("claude", .needsAttention)))
}

@Test func aDraftOrAnUnreadBoxKeepsItAwake() {
    #expect(HibernationEligibility.keepsAwake(pane("claude", .idle, box: false)))
    #expect(HibernationEligibility.keepsAwake(pane("claude", .idle, box: nil)))
}

@Test func anAgentWhoseStatusIsUnknownKeepsItAwake() {
    // Hooks off, or a harness that has not reported yet: idle is not proven.
    #expect(HibernationEligibility.keepsAwake(pane("claude", nil, box: true)))
}

@Test func aNonAgentForegroundCommandKeepsItAwake() {
    #expect(HibernationEligibility.keepsAwake(pane("nvim")))
    #expect(HibernationEligibility.keepsAwake(pane("npm")))
}

@Test func aHarnessWithNoHandoffGrammarKeepsItAwakeAsBefore() {
    #expect(HibernationEligibility.keepsAwake(pane("aider", .idle, box: true)))
}

@Test func onlyAnIdleHandoffAgentNeedsItsBoxRead() {
    #expect(HibernationEligibility.needsPromptBox(pane("claude", .idle)))
    #expect(!HibernationEligibility.needsPromptBox(pane("claude", .running)))
    #expect(!HibernationEligibility.needsPromptBox(pane("nvim")))
    #expect(!HibernationEligibility.needsPromptBox(pane("")))
}

@Test func theIdleClockRunsFromTheLatestSignal() {
    let now = Date(timeIntervalSince1970: 10_000)
    let used = Date(timeIntervalSince1970: 4_000)
    let transcript = Date(timeIntervalSince1970: 9_000)
    #expect(HibernationPolicy.idleFor(now: now, lastUsedAt: used, transcripts: [transcript]) == 1_000)
    #expect(HibernationPolicy.idleFor(now: now, lastUsedAt: used, transcripts: []) == 6_000)
    // Nothing known yet is a full window before it is eligible.
    #expect(HibernationPolicy.idleFor(now: now, lastUsedAt: nil, transcripts: []) == 0)
}

// An agent whose turn has ended reports idle and shows an empty box while a
// server it started keeps running. Before handoffs any foreground process
// kept the project awake, so that server was safe; it has to stay safe.
@Test func anIdleAgentWithWorkStillRunningKeepsItAwake() {
    #expect(HibernationEligibility.keepsAwake(pane("claude", .idle, box: true, work: true)))
    #expect(HibernationEligibility.keepsAwake(pane("claude", .needsAttention, box: true, work: true)))
    // Nothing on its screen can change that, so it is not read.
    #expect(!HibernationEligibility.needsPromptBox(pane("claude", .idle, work: true)))
}
