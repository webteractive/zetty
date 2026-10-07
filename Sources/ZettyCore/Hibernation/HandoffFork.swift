import Foundation

/// The headless fork that writes a pane's handoff.
///
/// A FORK, never the live pane: it needs no empty prompt box, never appends
/// to the original transcript, and can run after the pane's agent is gone —
/// which is what lets hibernation stay instant. Grammar verified 2026-10-07
/// against claude 2.1.292 and codex 0.160.1.
public enum HandoffFork {
    /// A run past this is abandoned; the pane wakes without a handoff.
    public static let timeout: TimeInterval = 300

    public static func supports(_ kind: AgentKind) -> Bool {
        arguments(agent: kind, sessionID: "probe", request: "x") != nil
    }

    /// The harness's arguments, or nil for a harness with no verified grammar
    /// or an id that fails validation. The caller runs it with stdin at
    /// `/dev/null`: `claude -p` otherwise waits 3 seconds for piped input.
    public static func arguments(agent: AgentKind, sessionID: String, request: String) -> [String]? {
        guard AgentEvent.isValidSessionID(sessionID) else { return nil }
        switch agent {
        case .claude:
            // `--tools ""` is what stops it acting — the person's own allow
            // rules could let a tool run for real — and `--permission-prompts
            // none` sits between it and the request because `--tools` is
            // variadic. No `--model`: a long session may not fit a smaller
            // one's context.
            return ["-p", "--resume", sessionID, "--fork-session", "--no-session-persistence",
                    "--tools", "", "--permission-prompts", "none", request]
        case .codex:
            // `exec` runs with approvals off and a read-only sandbox, and a
            // pane's directory need not be a repository.
            return ["exec", "fork", sessionID, "--ephemeral", "--skip-git-repo-check", request]
        default:
            return nil
        }
    }

    /// The fork's environment: the app's, minus anything that would make it
    /// look like a pane or like part of somebody's agent session, minus every
    /// login variable, plus the login the session belongs to. No login
    /// variable at all is the default login.
    ///
    /// `ZETTY` goes because the app sets it on itself and the hook helper
    /// reports whenever it is set, matching panes by directory when it has no
    /// surface to name: a fork carrying it would flip other panes' dots. The
    /// mod is left out too; a fork has nothing to tell the chrome. `USER`
    /// stays by not being removed: Claude reads an account's Keychain login
    /// through it.
    public static func environment(base: [String: String], account: [String: String]) -> [String: String] {
        var dropped = Set(LaunchEnvironment.agentSessionKeys)
        dropped.formUnion(SpawnableAgent.accountCapable.compactMap(\.configDirEnvVar))
        dropped.formUnion(["ZMX_SESSION", ModInstall.pluginDirsVariable])
        var environment = base.filter { key, _ in !key.hasPrefix("ZETTY") && !dropped.contains(key) }
        environment.merge(EnvDirective.sanitized(account)) { _, new in new }
        return environment
    }
}
