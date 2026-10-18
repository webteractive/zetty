import Foundation

/// Handing a pane's work to a fresh agent session, on the same login or
/// another (`zetty handoff`, the pane gutter's handoff button, the Claude
/// mod's `/z-handoff`).
///
/// The agent writes a brief to a file, quits, and a new session is started
/// in the same pane under the chosen login, told to read the brief. A file
/// rather than a resume, because each account keeps its own transcripts: the
/// other login cannot `--resume` this conversation, and a Codex cannot resume
/// a Claude's. The brief is temporary (`PendingBrief`).
///
/// Not the hibernation handoff (`HandoffRecord`), which compacts the
/// conversation in place and resumes that same conversation on wake.
public enum AgentHandoff {

    /// Which harness the new session runs, and under which login.
    public struct Target: Equatable, Sendable {
        public let agent: AgentKind
        /// `AgentAccountSupport.defaultID` for the harness's default login.
        public let accountID: String

        public init(agent: AgentKind, accountID: String) {
            self.agent = agent
            self.accountID = accountID
        }
    }

    /// The harnesses a session can be handed to: each has a way to start
    /// with a first prompt, and a quit line for when it is handed on again.
    public static let agents: [AgentKind] = [.claude, .codex]

    /// What `name` asks for, from a pane running `current` under
    /// `currentAccountID`. nil or empty is a fresh session on the same
    /// login; `claude` and `codex` are that harness's default login; anything
    /// else is an account, case-insensitively, by its handle (`claude-devops`,
    /// see `handle(for:)`), the name of its `claude-<account>` command, its
    /// name or its id.
    ///
    /// The harness names come first, so they always mean the default login.
    /// An unknown name is an error listing the choices, never a fallback to
    /// the default login: landing on the wrong account is what accounts exist
    /// to prevent (the rule `--account` follows).
    public static func resolve(_ name: String?, current: AgentKind, currentAccountID: String,
                               accounts: [AgentAccount]) -> Result<Target, HandoffError> {
        let wanted = (name ?? "").trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty { return .success(Target(agent: current, accountID: currentAccountID)) }
        let lowered = wanted.lowercased()
        if let agent = agents.first(where: { $0.rawValue == lowered }) {
            return .success(Target(agent: agent, accountID: AgentAccountSupport.defaultID))
        }
        guard let account = accounts.first(where: { account in
            [handle(for: account), AccountShim.name(for: account), account.name, account.id]
                .contains { $0.lowercased() == lowered }
        }) else {
            return .failure(.unknownTarget(wanted, choices: choiceNames(accounts: accounts)))
        }
        guard let agent = AgentKind(rawValue: account.agentID), agents.contains(agent) else {
            return .failure(.unsupportedAgent(account.name))
        }
        return .success(Target(agent: agent, accountID: account.id))
    }

    /// Every target a pane can be handed to, in menu order: each harness's
    /// default login, then its accounts by name. `name` is the handle
    /// `resolve` takes, the same one `/z-handoff` lists.
    public static func targets(accounts: [AgentAccount]) -> [(target: Target, name: String?, title: String)] {
        agents.flatMap { agent -> [(target: Target, name: String?, title: String)] in
            let own = accounts.filter { $0.agentID == agent.rawValue }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return [(Target(agent: agent, accountID: AgentAccountSupport.defaultID), agent.rawValue,
                     "\(agent.displayName) · Default")]
                + own.map { (Target(agent: agent, accountID: $0.id), handle(for: $0),
                             "\(agent.displayName) · \($0.name)") }
        }
    }

    /// An account's name on the handoff's command line: its harness and its
    /// id, `claude-devops`. The id, not the name, so it survives a rename,
    /// and so the mod can build it from `zetty accounts --json` without
    /// Zetty's slug rule (Glen, 2026-10-18: `/z-handoff claude-devops`).
    public static func handle(for account: AgentAccount) -> String {
        "\(account.agentID)-\(account.id)"
    }

    private static func choiceNames(accounts: [AgentAccount]) -> [String] {
        agents.map(\.rawValue) + accounts
            .filter { account in agents.contains { $0.rawValue == account.agentID } }
            .map(handle(for:))
    }

    /// Where the brief for `surface` is written. One per pane, so a second
    /// handoff of the same pane replaces it rather than piling up.
    public static func briefPath(for surface: UUID, home: String) -> String {
        (home as NSString).appendingPathComponent(".zetty/transfers/\(surface.uuidString).md")
    }

    /// What the outgoing agent is asked to do, typed into its prompt box (or
    /// submitted by the mod). One line: a newline typed into a harness's box
    /// would submit it half-written.
    public static func writePrompt(briefPath: String) -> String {
        "Write a handoff brief to \(briefPath) for a fresh session that will take over this work in this "
            + "directory. It starts with nothing but that file, so make it self-contained: the goal, what is "
            + "done and what is verified, decisions made and why, the files involved, anything uncommitted "
            + "or half-done, open questions, and the exact next step. Markdown, as long as it needs and no "
            + "longer. Write the file and stop there: this session ends once it exists."
    }

    /// The first prompt of the new session.
    public static func readPrompt(briefPath: String) -> String {
        "Read the handoff brief at \(briefPath): a previous session working here wrote it for you. "
            + "Say in a few lines where things stand, then continue with its next step."
    }

    /// The line typed into the pane's shell once the old agent has quit:
    /// the harness under `login`, started on its first prompt, in `cwd`.
    /// nil for a harness that cannot be handed to.
    public static func launchLine(agent: AgentKind, login: ResumeLogin, cwd: String,
                                  briefPath: String) -> String? {
        guard agents.contains(agent) else { return nil }
        let prefix = RestartRecovery.loginPrefix(environment: login.environment, unsetting: login.unsetting)
        let prompt = ShellQuote.singleQuoted(readPrompt(briefPath: briefPath))
        return "cd \(ShellQuote.singleQuoted(cwd)) && \(prefix)\(RestartRecovery.harnessCommand(for: agent)) \(prompt)"
    }

    /// The word on the launch line that the new harness's input box is
    /// looked for below (`PromptBox.showsInput`): the brief's file name,
    /// which no line above the launch holds once it has been typed.
    public static func launchMarker(briefPath: String) -> String {
        (briefPath as NSString).lastPathComponent
    }

    /// A brief left behind (its session never took a turn, or hooks are
    /// off) is removed at launch after a day.
    public static let staleAfter: TimeInterval = 24 * 60 * 60

    /// How long the outgoing agent has to write its brief.
    public static let writeTimeout: TimeInterval = 10 * 60
}

public enum HandoffError: Error, Equatable, LocalizedError {
    case unknownTarget(String, choices: [String])
    case unsupportedAgent(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTarget(let name, let choices):
            return "no account or agent named \"\(name)\" — choose one of: \(choices.joined(separator: ", "))"
        case .unsupportedAgent(let name):
            return "account \"\(name)\" is for a harness that cannot be handed to (Claude and Codex can)"
        }
    }
}

/// A brief the new session has been told to read, deleted once it has.
///
/// "Once it has" is the end of its first turn, which reading the brief is.
/// Claude reports `idle` as it STARTS (its SessionStart hook), before it has
/// read anything, so only an `idle` after a `running` counts there. Codex's
/// one hook is turn ended, so its first `idle` is that turn. The session
/// ending counts too: nobody is left to read it.
public struct PendingBrief: Equatable, Sendable {
    public let path: String
    public let agent: AgentKind
    public private(set) var sawTurn = false

    public init(path: String, agent: AgentKind) {
        self.path = path
        self.agent = agent
    }

    /// Takes in a hook event from the new session; true when the brief has
    /// served its purpose and can be deleted.
    public mutating func observe(_ event: AgentEvent.Kind) -> Bool {
        switch event {
        case .running:
            sawTurn = true
            return false
        case .idle, .needsAttention:
            return agent == .codex || sawTurn
        case .ended:
            return true
        }
    }
}
