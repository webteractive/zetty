import Foundation

/// Whether a pane's agent can be picked up where it left off, and with what.
///
/// One entry point, deliberately: the answer to "does this harness support
/// resume" is `RestartRecovery.resumeCommand` returning non-nil, and nothing
/// else. A separate `supports(_:)` predicate would be a second list to keep in
/// step with the grammar, and the two would disagree the moment a harness was
/// added — offering a button that types a command the builder refuses to make.
public enum AgentResume {

    /// The line that resumes this pane's agent, or nil when it cannot be.
    ///
    /// nil covers every reason at once: no agent detected, a harness with no
    /// verified resume grammar (opencode, aider, gemini, hermes), no session id
    /// yet, or an id that fails validation. Callers show the control exactly
    /// when this is non-nil, so an offered action can never fail to build.
    public static func command(for state: AgentState) -> String? {
        guard let kind = state.kind, let session = state.session else { return nil }
        return RestartRecovery.resumeCommand(agent: kind, sessionID: session.id,
                                             cwd: session.cwd)
    }

    /// What to type to make this harness quit cleanly, or nil when it has no
    /// known one.
    ///
    /// A restart types this into the LIVE pane and waits for the agent to go,
    /// rather than killing the pane — so the zmx session, and with it the
    /// pane's scrollback, survives. nil is a refusal, never a guess: sending
    /// the wrong line to an agent leaves it running with a stray message typed
    /// into its prompt.
    public static func exitCommand(for kind: AgentKind) -> String? {
        switch kind {
        case .claude: return "/exit"
        case .codex:  return "/quit"
        default:      return nil
        }
    }

    /// Whether a restart can be driven end to end: a way out AND a way back.
    public static func canRestart(_ kind: AgentKind) -> Bool {
        exitCommand(for: kind) != nil
            && RestartRecovery.resumeCommand(agent: kind, sessionID: "probe", cwd: "/") != nil
    }
}
