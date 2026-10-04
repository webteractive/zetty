import Foundation
import Testing
@testable import ZettyCore

private func state(_ kind: AgentKind?, id: String?, cwd: String = "/w/proj") -> AgentState {
    AgentState(kind: kind, status: .idle,
               session: id.map { AgentSession(id: $0, cwd: cwd) })
}

@Test func aClaudePaneWithASessionResumes() {
    let command = AgentResume.command(for: state(.claude, id: "abc-123"))
    #expect(command == "cd '/w/proj' && claude --resume 'abc-123'")
}

@Test func aCodexPaneUsesItsOwnGrammar() {
    let command = AgentResume.command(for: state(.codex, id: "019a-bb"))
    #expect(command == "cd '/w/proj' && codex resume '019a-bb'")
}

@Test func aHarnessWithNoVerifiedResumeGrammarOffersNothing() {
    // The control is shown exactly when this is non-nil, so these are the
    // panes that must not grow a refresh button.
    for kind in [AgentKind.opencode, .aider, .gemini, .hermes] {
        #expect(AgentResume.command(for: state(kind, id: "abc-123")) == nil)
    }
}

@Test func aPaneWithNoAgentOrNoSessionOffersNothing() {
    #expect(AgentResume.command(for: state(nil, id: "abc-123")) == nil)
    #expect(AgentResume.command(for: state(.claude, id: nil)) == nil)
}

@Test func aSessionIDThatFailsValidationOffersNothing() {
    // Defence in depth: the id reaches a shell command, and the hook parser
    // already rejects these. A refresh button must never be offered for one.
    for bad in ["a b", "id;rm -rf /", "'", "", String(repeating: "x", count: 129)] {
        #expect(AgentResume.command(for: state(.claude, id: bad)) == nil)
    }
}

@Test func theCwdIsQuotedSoAPathWithSpacesSurvives() {
    let command = AgentResume.command(for: state(.claude, id: "abc", cwd: "/w/my proj"))
    #expect(command == "cd '/w/my proj' && claude --resume 'abc'")
}

@Test func eachResumableHarnessHasItsOwnQuitLine() {
    #expect(AgentResume.exitCommand(for: .claude) == "/exit")
    #expect(AgentResume.exitCommand(for: .codex) == "/quit")
}

@Test func aHarnessWithNoKnownQuitLineRefusesRatherThanGuessing() {
    // The line is typed into a LIVE agent. A guess leaves it running with a
    // stray message sitting in its prompt.
    for kind in [AgentKind.opencode, .aider, .gemini, .hermes] {
        #expect(AgentResume.exitCommand(for: kind) == nil)
        #expect(AgentResume.canRestart(kind) == false)
    }
}

@Test func restartNeedsBothAWayOutAndAWayBack() {
    #expect(AgentResume.canRestart(.claude))
    #expect(AgentResume.canRestart(.codex))
}

@Test func aResumeCanBePinnedToAnAccountLogin() {
    // After `zetty run`, the pane's shell still holds the SPAWN account, so the
    // resume has to name the running login itself.
    let command = AgentResume.command(
        for: state(.claude, id: "abc-123"),
        login: ResumeLogin(environment: ["CLAUDE_CONFIG_DIR": "/Users/g/.zetty/accounts/work"]))
    #expect(command
            == "cd '/w/proj' && CLAUDE_CONFIG_DIR='/Users/g/.zetty/accounts/work' claude --resume 'abc-123'")
}

@Test func anUnsafeEnvironmentPairIsDroppedNotTyped() {
    // A key that is not a shell name would run as a COMMAND; a control
    // character would end the line early.
    let command = AgentResume.command(
        for: state(.codex, id: "019a"),
        login: ResumeLogin(environment: ["rm -rf ~;X": "1", "CODEX_HOME": "/a\nb", "1BAD": "x"]))
    #expect(command == "cd '/w/proj' && codex resume '019a'")
}

@Test func aResumeCanDropTheShellsAccountToReachTheDefaultLogin() {
    // The default login in a pane spawned on an account: the variable has to
    // be ABSENT for the harness, not assigned something else.
    let command = AgentResume.command(
        for: state(.claude, id: "abc-123"),
        login: ResumeLogin(unsetting: ["CLAUDE_CONFIG_DIR"]))
    #expect(command == "cd '/w/proj' && env -u CLAUDE_CONFIG_DIR claude --resume 'abc-123'")
}

@Test func anUnsafeNameToUnsetIsDroppedNotTyped() {
    let command = AgentResume.command(
        for: state(.codex, id: "019a"),
        login: ResumeLogin(unsetting: ["X; rm -rf ~", "CODEX_HOME"]))
    #expect(command == "cd '/w/proj' && env -u CODEX_HOME codex resume '019a'")
}
