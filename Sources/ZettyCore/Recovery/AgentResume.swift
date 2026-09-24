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
}
