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
