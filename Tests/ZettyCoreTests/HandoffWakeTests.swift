import Foundation
import Testing
@testable import ZettyCore

private func record(_ agent: AgentKind, session: String = "abc-123") -> HandoffRecord {
    HandoffRecord(surface: UUID(), agent: agent, sessionID: session, cwd: "/Users/me/app",
                  accountID: nil, requestedAt: Date(timeIntervalSince1970: 0))
}

private let wake = ShellQuote.singleQuoted(HandoffCompaction.wakeLine)

@Test func aPaneWakesByResumingItsCompactedConversation() {
    #expect(HandoffWake.command(record: record(.claude), login: .inherited)
            == "cd '/Users/me/app' && claude --resume 'abc-123' \(wake)")
    #expect(HandoffWake.command(record: record(.codex), login: .inherited)
            == "cd '/Users/me/app' && codex resume 'abc-123' \(wake)")
}

@Test func theWakeComesBackUnderTheAgentsLogin() {
    let account = ResumeLogin(environment: ["CLAUDE_CONFIG_DIR": "/Users/me/.zetty/accounts/work"])
    #expect(HandoffWake.command(record: record(.claude), login: account)
            == "cd '/Users/me/app' && CLAUDE_CONFIG_DIR='/Users/me/.zetty/accounts/work' "
            + "claude --resume 'abc-123' \(wake)")
    let defaultLogin = ResumeLogin(unsetting: ["CODEX_HOME"])
    #expect(HandoffWake.command(record: record(.codex), login: defaultLogin)
            == "cd '/Users/me/app' && env -u CODEX_HOME codex resume 'abc-123' \(wake)")
}

@Test func aHarnessThatCannotCompactOrABadSessionHasNoWakeLine() {
    #expect(HandoffWake.command(record: record(.gemini), login: .inherited) == nil)
    #expect(HandoffWake.command(record: record(.claude, session: "abc'; rm -rf ~"), login: .inherited) == nil)
}

@Test func aRecordWakesByResumingAndNoRecordAsAPlainShell() {
    let claude = record(.claude)
    #expect(HandoffWake.plan(record: claude, login: .inherited)
            == .resume("cd '/Users/me/app' && claude --resume 'abc-123' \(wake)"))
    #expect(HandoffWake.plan(record: nil, login: .inherited) == .plainShell)
    #expect(HandoffWake.plan(record: record(.gemini), login: .inherited) == .plainShell)
}

// The wake line is one shell argument: a quote in it must not end the
// quoting, and a newline would be typed as Enter.
@Test func theWakeLineIsASingleQuotableLine() {
    #expect(!HandoffCompaction.wakeLine.contains("\n"))
    #expect(wake.hasPrefix("'") && wake.hasSuffix("'"))
}

// MARK: - Picking how a pane comes back

@Test func aFreshAgentStartsANewConversationUnderTheSameLogin() {
    #expect(HandoffWake.plan(record: record(.claude), choice: .fresh, login: .inherited)
            == .fresh("cd '/Users/me/app' && claude"))
    let account = ResumeLogin(environment: ["CODEX_HOME": "/Users/me/.zetty/accounts/work"])
    #expect(HandoffWake.plan(record: record(.codex), choice: .fresh, login: account)
            == .fresh("cd '/Users/me/app' && CODEX_HOME='/Users/me/.zetty/accounts/work' codex"))
}

@Test func aShellIsAShellWhateverThePaneHeld() {
    #expect(HandoffWake.plan(record: record(.claude), choice: .shell, login: .inherited) == .plainShell)
    #expect(HandoffWake.plan(record: nil, choice: .fresh, login: .inherited) == .plainShell)
    #expect(HandoffWake.plan(record: record(.gemini), choice: .fresh, login: .inherited) == .plainShell)
}

// The choice rides in the record once a pane is woken, so a wake line a quit
// lost is typed again the way it was chosen. Records written before it
// existed carry none, which is resume.
@Test func aRecordRemembersHowItWasWoken() throws {
    var chosen = record(.claude)
    chosen.wake = .fresh
    let data = try JSONEncoder().encode(chosen)
    #expect(try JSONDecoder().decode(HandoffRecord.self, from: data).wake == .fresh)
    let old = try JSONEncoder().encode(record(.claude))
    #expect(try JSONDecoder().decode(HandoffRecord.self, from: old).wake == nil)
}

