import Foundation

/// Variables the GUI must not inherit from whatever launched it.
///
/// `open -a` from a terminal hands the app that shell's environment, and a
/// pane on the Default login sets no config-dir variable of its own — it
/// inherits the app's. Relaunching Zetty from a pane running a `devops`
/// account therefore put EVERY Default pane on `devops`, and leaked that
/// pane's `ZMX_SESSION` / `ZETTY_SURFACE` into the app. Account panes set their
/// variable explicitly, and every pane gets its own `ZETTY_SURFACE` and
/// `ZETTY_CWD_FILE`, so removing these at launch changes nothing a pane is
/// meant to have.
///
/// Cleared only on the GUI path: the CLI runs inside panes and needs them.
public enum LaunchEnvironment {

    public static var inheritedKeysToClear: [String] {
        ["ZMX_SESSION", "ZETTY_SURFACE", "ZETTY_CWD_FILE", AccountRun.accountEnvVar]
            + SpawnableAgent.accountCapable.compactMap(\.configDirEnvVar)
            + agentSessionKeys
    }

    /// What a harness exports to the commands it runs: which session the
    /// shell belongs to, how to message it, that an agent is driving it. The
    /// install ritual has an agent relaunch Zetty with `open -a`, and every
    /// pane created afterwards then claimed to be inside that agent's session
    /// — its id and its messaging token included.
    ///
    /// Named one by one, never by prefix: `CLAUDE_CODE_` is shared with
    /// settings people export themselves (`CLAUDE_CODE_NO_FLICKER`) and with
    /// `CLAUDE_CODE_PLUGIN_DIRS`, which `AppDelegate` keeps current. Read off
    /// claude 2.1.292 and codex 0.160.1; a harness update can add to it.
    public static let agentSessionKeys = [
        "AI_AGENT",
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CODEX_CI", "CODEX_VERSION", "CODEX_SESSION_ID", "CODEX_THREAD_ID",
        "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_PERMISSION_PROFILE",
    ]

    /// Removes `inheritedKeysToClear` from this process. Call before the first
    /// pane spawns.
    public static func clearInherited() {
        for key in inheritedKeysToClear { unsetenv(key) }
    }
}
