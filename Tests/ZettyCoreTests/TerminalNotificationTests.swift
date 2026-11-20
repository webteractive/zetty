import Testing
@testable import ZettyCore

@Test func claudeNotificationsNeverSetState() {
    // The mod and hooks label Claude's notifications; its OSC 777 only
    // collapses into the banner they raised.
    #expect(TerminalNotification.classify(title: "Claude Code", body: "Claude needs your permission to use Bash",
                                          agent: .claude) == .noState)
}

@Test func codexApprovalIsADecision() {
    #expect(TerminalNotification.classify(title: nil, body: "Approval requested: rm -rf build", agent: .codex)
            == .decision("Approval requested: rm -rf build"))
    #expect(TerminalNotification.classify(title: nil, body: "Approval requested by reviewer", agent: .codex)
            == .decision("Approval requested by reviewer"))
    #expect(TerminalNotification.classify(title: nil, body: "Question requested", agent: .codex)
            == .decision("Question requested"))
    #expect(TerminalNotification.classify(title: nil, body: "Implement this plan?", agent: .codex)
            == .decision("Implement this plan?"))
}

@Test func codexEditIsADecision() {
    #expect(TerminalNotification.classify(title: nil, body: "Codex wants to edit 3 files", agent: .codex)
            == .decision("Codex wants to edit 3 files"))
}

@Test func codexTurnEndIsFinished() {
    #expect(TerminalNotification.classify(title: nil, body: "Agent turn complete", agent: .codex)
            == .finished("Agent turn complete"))
    #expect(TerminalNotification.classify(title: nil, body: "  Refactored the parser.  ", agent: .codex)
            == .finished("Refactored the parser."))
}

@Test func unknownAgentPlainTextIsFinished() {
    #expect(TerminalNotification.classify(title: "Build", body: nil, agent: nil) == .finished("Build"))
    #expect(TerminalNotification.classify(title: nil, body: "done", agent: .hermes) == .finished("done"))
}

@Test func emptyNotificationIsFinishedWithEmptyText() {
    #expect(TerminalNotification.classify(title: nil, body: nil, agent: .codex) == .finished(""))
}

// MARK: - Progress (OSC 9;4)

@Test func progressNeverMovesAPaneOutOfNeedsYou() {
    // Claude may clear or re-send its progress while it waits to ask.
    #expect(TerminalProgressPolicy.report(active: true, current: .needsAttention) == nil)
    #expect(TerminalProgressPolicy.report(active: false, current: .needsAttention) == nil)
}

@Test func progressSetIsRunningAndClearEndsARunningTurn() {
    #expect(TerminalProgressPolicy.report(active: true, current: nil) == .running)
    #expect(TerminalProgressPolicy.report(active: true, current: .idle) == .running)
    #expect(TerminalProgressPolicy.report(active: false, current: .running) == .idle)
    #expect(TerminalProgressPolicy.report(active: false, current: .idle) == nil)
}

/// Codex's only hook is the turn's end and it sends no progress, so after
/// you approve, nothing it says moves the pane off yellow until the turn
/// ends. A key typed into the waiting pane is the answer (release review,
/// 2026-11-20). Claude's and Hermes's hooks report moving on themselves.
@Test func aKeyInAWaitingCodexPaneAnswersIt() {
    #expect(PromptAnswerPolicy.report(agent: .codex, current: .needsAttention) == .running)
    #expect(PromptAnswerPolicy.report(agent: .codex, current: .running) == nil)
    #expect(PromptAnswerPolicy.report(agent: .codex, current: .idle) == nil)
    #expect(PromptAnswerPolicy.report(agent: .claude, current: .needsAttention) == nil)
    #expect(PromptAnswerPolicy.report(agent: nil, current: .needsAttention) == nil)
}

/// Only a key the pane's program receives answers it. ⌘ chords belong to
/// the menus: ⌘C to copy the command Codex wants approved, or switching
/// project, turned the pane green while Codex still waited (review of
/// 70c34a5, 2026-11-20).
@Test func onlyKeysTheProgramGetsAnswerAPrompt() {
    #expect(PromptAnswerPolicy.answers(KeyChord.parse("y")!))
    #expect(PromptAnswerPolicy.answers(KeyChord.parse("enter")!))
    #expect(PromptAnswerPolicy.answers(KeyChord.parse("ctrl+c")!))
    #expect(!PromptAnswerPolicy.answers(KeyChord.parse("cmd+c")!))
    #expect(!PromptAnswerPolicy.answers(KeyChord.parse("cmd+shift+]")!))
}
