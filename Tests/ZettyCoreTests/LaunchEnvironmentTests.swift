import Testing
@testable import ZettyCore

// Relaunching from an account pane must not hand that login to every Default
// pane, nor that pane's own identity to the app.
@Test func launchClearsEveryAccountConfigDirAndPaneIdentity() {
    let keys = Set(LaunchEnvironment.inheritedKeysToClear)
    #expect(keys.isSuperset(of: ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "ZMX_SESSION",
                                 "ZETTY_SURFACE", "ZETTY_CWD_FILE", "ZETTY_ACCOUNT"]))
    // The hook guard reads this, and the app sets it itself.
    #expect(!keys.contains("ZETTY"))
}

// An agent that relaunches the app (the install ritual runs `open -a` from its
// own pane) must not leave its session in every pane created afterwards.
@Test func launchClearsTheRelaunchingAgentsSession() {
    let keys = Set(LaunchEnvironment.inheritedKeysToClear)
    #expect(keys.isSuperset(of: ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
                                 "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
                                 "CLAUDE_PID", "AI_AGENT", "CODEX_THREAD_ID", "CODEX_SANDBOX"]))
    // Settings, not a session: the first is the person's own export, and
    // AppDelegate keeps the second current.
    #expect(!keys.contains("CLAUDE_CODE_NO_FLICKER"))
    #expect(!keys.contains("CLAUDE_CODE_PLUGIN_DIRS"))
}
