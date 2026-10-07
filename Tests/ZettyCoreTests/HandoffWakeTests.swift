import Foundation
import Testing
@testable import ZettyCore

private let path = "/Users/me/.zetty/handoffs/045C5269.md"

@Test func claudeWakesByMentioningTheFile() {
    #expect(HandoffWake.command(agent: .claude, handoffPath: path, cwd: "/Users/me/app", login: .inherited)
            == "cd '/Users/me/app' && claude '@/Users/me/.zetty/handoffs/045C5269.md'")
}

@Test func aPathAMentionCannotCarryIsReadByTheShellInstead() {
    #expect(HandoffWake.command(agent: .claude, handoffPath: "/Users/John Smith/.zetty/handoffs/x.md",
                                cwd: "/tmp", login: .inherited)
            == "cd '/tmp' && claude \"$(cat '/Users/John Smith/.zetty/handoffs/x.md')\"")
}

@Test func codexAlwaysGetsTheTextAsItsFirstMessage() {
    #expect(HandoffWake.command(agent: .codex, handoffPath: path, cwd: "/Users/me/app", login: .inherited)
            == "cd '/Users/me/app' && codex \"$(cat '/Users/me/.zetty/handoffs/045C5269.md')\"")
}

@Test func theWakeComesBackUnderTheAgentsLogin() {
    let account = ResumeLogin(environment: ["CLAUDE_CONFIG_DIR": "/Users/me/.zetty/accounts/work"])
    #expect(HandoffWake.command(agent: .claude, handoffPath: path, cwd: "/a", login: account)
            == "cd '/a' && CLAUDE_CONFIG_DIR='/Users/me/.zetty/accounts/work' claude '@\(path)'")
    let defaultLogin = ResumeLogin(unsetting: ["CODEX_HOME"])
    #expect(HandoffWake.command(agent: .codex, handoffPath: path, cwd: "/a", login: defaultLogin)
            == "cd '/a' && env -u CODEX_HOME codex \"$(cat '\(path)')\"")
}

@Test func aHarnessWithNoGrammarHasNoWakeLine() {
    #expect(HandoffWake.command(agent: .gemini, handoffPath: path, cwd: "/a", login: .inherited) == nil)
}

private let record = HandoffRecord(surface: UUID(), agent: .claude, sessionID: "abc-123",
                                   cwd: "/Users/me/app", accountID: nil,
                                   requestedAt: Date(timeIntervalSince1970: 0))

@Test func aReadyHandoffWakesFresh() {
    let plan = HandoffWake.plan(record: record, handoffReady: true, forkPending: false,
                                handoffPath: path, login: .inherited)
    #expect(plan == .fresh("cd '/Users/me/app' && claude '@\(path)'"))
}

@Test func wakingBeforeTheHandoffIsReadyResumesTheOldConversation() {
    let plan = HandoffWake.plan(record: record, handoffReady: false, forkPending: true,
                                handoffPath: path, login: .inherited)
    #expect(plan == .resume("cd '/Users/me/app' && claude --resume 'abc-123'"))
}

@Test func aReadyHandoffWinsOverAStaleQueueEntry() {
    let plan = HandoffWake.plan(record: record, handoffReady: true, forkPending: true,
                                handoffPath: path, login: .inherited)
    #expect(plan == .fresh("cd '/Users/me/app' && claude '@\(path)'"))
}

@Test func noRecordOrAFailedForkWakesAsBefore() {
    #expect(HandoffWake.plan(record: nil, handoffReady: false, forkPending: false,
                             handoffPath: path, login: .inherited) == .plainShell)
    #expect(HandoffWake.plan(record: record, handoffReady: false, forkPending: false,
                             handoffPath: path, login: .inherited) == .plainShell)
}
