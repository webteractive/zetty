import Foundation

/// How a hibernated pane comes back.
public enum HandoffWake {

    /// What the person picks for a pane that left a handoff, on the
    /// hibernated project's screen or with `zetty wake --fresh | --shell`.
    public enum Choice: String, Codable, Sendable, CaseIterable {
        /// The agent's own conversation, compacted before it was put away.
        case resume
        /// The same harness under the same login, with a new conversation.
        /// The compacted one stays in the harness's history.
        case fresh
        /// No agent: a shell at the pane's directory.
        case shell
    }

    public enum Plan: Equatable, Sendable {
        case resume(String)
        case fresh(String)
        /// As before handoffs: a shell at the pane's directory.
        case plainShell

        public var logName: String {
            switch self {
            case .resume:     return "resume"
            case .fresh:      return "fresh"
            case .plainShell: return "plain"
            }
        }
    }

    /// A project is only put away once its agents have compacted, so a pane
    /// either has a record to come back from or never had an agent.
    public static func plan(record: HandoffRecord?, choice: Choice = .resume, login: ResumeLogin) -> Plan {
        guard let record else { return .plainShell }
        switch choice {
        case .resume: return command(record: record, login: login).map(Plan.resume) ?? .plainShell
        case .fresh:  return freshCommand(record: record, login: login).map(Plan.fresh) ?? .plainShell
        case .shell:  return .plainShell
        }
    }

    /// A new conversation in the pane's harness, under the login the old one
    /// ran as: a pane spawned on one account whose agent ran on another would
    /// otherwise come back on the wrong one.
    public static func freshCommand(record: HandoffRecord, login: ResumeLogin) -> String? {
        guard HandoffCompaction.supports(record.agent) else { return nil }
        let prefix = RestartRecovery.loginPrefix(environment: login.environment, unsetting: login.unsetting)
        return "cd \(ShellQuote.singleQuoted(record.cwd)) && "
            + "\(prefix)\(RestartRecovery.harnessCommand(for: record.agent))"
    }

    /// The line typed into the woken pane's shell: the ordinary resume line
    /// with a first message, so the agent says where things stand instead of
    /// sitting silent at its prompt. Both harnesses take that message as
    /// the argument after the session (`claude --resume <id> <prompt>`,
    /// `codex resume <id> <prompt>`).
    public static func command(record: HandoffRecord, login: ResumeLogin) -> String? {
        guard HandoffCompaction.supports(record.agent),
              let resume = RestartRecovery.resumeCommand(
                  agent: record.agent, sessionID: record.sessionID, cwd: record.cwd,
                  environment: login.environment, unsetting: login.unsetting) else { return nil }
        return "\(resume) \(ShellQuote.singleQuoted(HandoffCompaction.wakeLine))"
    }
}
