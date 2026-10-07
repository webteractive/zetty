import Foundation
import Testing
@testable import ZettyCore

/// Grammar verified 2026-10-07 against claude 2.1.292 and codex 0.160.1.

@Test func theClaudeForkCannotActOrPersist() throws {
    let argv = try #require(HandoffFork.arguments(agent: .claude, sessionID: "abc-123", request: "REQ"))
    #expect(argv == ["-p", "--resume", "abc-123", "--fork-session", "--no-session-persistence",
                     "--tools", "", "--permission-prompts", "none", "REQ"])
    // `--tools` is variadic: the request right after it would be read as a tool name.
    let tools = try #require(argv.firstIndex(of: "--tools"))
    #expect(argv[tools + 2].hasPrefix("--"))
}

@Test func theCodexForkIsEphemeral() {
    #expect(HandoffFork.arguments(agent: .codex, sessionID: "abc-123", request: "REQ")
            == ["exec", "fork", "abc-123", "--ephemeral", "--skip-git-repo-check", "REQ"])
}

@Test func otherHarnessesAndBadIdsHaveNoFork() {
    #expect(HandoffFork.arguments(agent: .aider, sessionID: "abc", request: "REQ") == nil)
    #expect(HandoffFork.arguments(agent: .claude, sessionID: "a b; rm", request: "REQ") == nil)
    #expect(HandoffFork.supports(.claude) && HandoffFork.supports(.codex))
    #expect(!HandoffFork.supports(.gemini))
}

@Test func theForkNeverCarriesAPanesIdentityOrAnAgentsSession() {
    // USER stays: Claude reads an account's Keychain login through it, and
    // without it reports "Not logged in".
    let base = ["PATH": "/usr/bin", "USER": "me", "ZETTY": "1", "ZETTY_SURFACE": "X",
                "ZETTY_CWD_FILE": "/p/X.cwd", "ZMX_SESSION": "zetty-x", "CLAUDECODE": "1",
                "CLAUDE_CODE_SESSION_ID": "s", "CLAUDE_CODE_MESSAGING_TOKEN": "t", "CLAUDE_PID": "1",
                "CODEX_THREAD_ID": "c", "AI_AGENT": "x", "CLAUDE_CONFIG_DIR": "/stale",
                "CODEX_HOME": "/stale", "CLAUDE_CODE_PLUGIN_DIRS": "/Users/me/.zetty/mods/zetty-bridge"]
    let env = HandoffFork.environment(base: base, account: ["CLAUDE_CONFIG_DIR": "/Users/me/.zetty/accounts/work"])
    #expect(env == ["PATH": "/usr/bin", "USER": "me",
                    "CLAUDE_CONFIG_DIR": "/Users/me/.zetty/accounts/work"])
    // The default login is every config-dir variable being absent.
    #expect(HandoffFork.environment(base: base, account: [:]) == ["PATH": "/usr/bin", "USER": "me"])
}

@Test func aSettingThePersonExportedSurvivesIntoTheFork() {
    let env = HandoffFork.environment(base: ["CLAUDE_CODE_NO_FLICKER": "1"], account: [:])
    #expect(env == ["CLAUDE_CODE_NO_FLICKER": "1"])
}
