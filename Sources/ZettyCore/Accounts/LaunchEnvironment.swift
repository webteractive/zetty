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
    }

    /// Removes `inheritedKeysToClear` from this process. Call before the first
    /// pane spawns.
    public static func clearInherited() {
        for key in inheritedKeysToClear { unsetenv(key) }
    }
}
