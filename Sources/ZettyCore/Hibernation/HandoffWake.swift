import Foundation

/// How a hibernated pane comes back.
public enum HandoffWake {

    public enum Plan: Equatable, Sendable {
        /// A fresh agent whose first message is the handoff.
        case fresh(String)
        /// The old conversation: the pane was woken before its handoff was ready.
        case resume(String)
        /// As before handoffs: a shell at the pane's directory.
        case plainShell

        public var logName: String {
            switch self {
            case .fresh:      return "fresh"
            case .resume:     return "resume"
            case .plainShell: return "plain"
            }
        }
    }

    public static func plan(record: HandoffRecord?, handoffReady: Bool, forkPending: Bool,
                            handoffPath: String, login: ResumeLogin) -> Plan {
        guard let record else { return .plainShell }
        if handoffReady,
           let command = command(agent: record.agent, handoffPath: handoffPath,
                                 cwd: record.cwd, login: login) {
            return .fresh(command)
        }
        // A wake within minutes reads as a change of mind: give the person
        // their conversation back rather than making them wait for a summary.
        if forkPending,
           let command = RestartRecovery.resumeCommand(
               agent: record.agent, sessionID: record.sessionID, cwd: record.cwd,
               environment: login.environment, unsetting: login.unsetting) {
            return .resume(command)
        }
        return .plainShell
    }

    /// The line typed into the woken pane's shell. Claude mentions the file,
    /// so the transcript shows a path and not two pages; Codex has no mention
    /// syntax we rely on, so the shell reads the file into its first message.
    /// `"$(cat '…')"` works in zsh, bash and fish 3.4+, and the resume line
    /// already depends on shell syntax (`cd … && …`).
    public static func command(agent: AgentKind, handoffPath: String, cwd: String,
                               login: ResumeLogin) -> String? {
        guard HandoffFork.supports(agent) else { return nil }
        let message: String
        switch agent {
        case .claude where isMentionable(handoffPath):
            message = ShellQuote.singleQuoted("@" + handoffPath)
        default:
            message = "\"$(cat \(ShellQuote.singleQuoted(handoffPath)))\""
        }
        let prefix = RestartRecovery.loginPrefix(environment: login.environment,
                                                 unsetting: login.unsetting)
        return "cd \(ShellQuote.singleQuoted(cwd)) && "
            + "\(prefix)\(RestartRecovery.harnessCommand(for: agent)) \(message)"
    }

    /// Whether a hook event proves the fresh agent has taken its handoff in,
    /// so the file can go. `startedWorking` is whether an EARLIER event since
    /// the wake reported the agent running.
    ///
    /// Claude reports `SessionStart` as it launches, BEFORE it expands the
    /// mention in its first message: deleting the file on that event left the
    /// agent holding a bare path to nothing. The event after the one that says
    /// it started working is the first that can only follow the message being
    /// read. It is counted since the wake, never read off the pane's status,
    /// which may still say `running` from an agent hibernated mid-turn.
    /// Codex's shell has read the file before Codex starts, and its one hook
    /// is turn ended.
    public static func provesHandoffRead(agent: AgentKind, startedWorking: Bool) -> Bool {
        agent == .codex || startedWorking
    }

    /// A mention ends at whitespace, and a quote in it would end the shell's.
    private static func isMentionable(_ path: String) -> Bool {
        !path.contains(where: { $0.isWhitespace || $0 == "'" })
    }
}
