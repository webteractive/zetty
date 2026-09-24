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
