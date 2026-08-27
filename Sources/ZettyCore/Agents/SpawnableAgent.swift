import Foundation

/// A per-project enabled agent + its launch command. Presence in
/// `ProjectSettings.agents` means "enabled".
public struct ProjectAgent: Codable, Sendable, Equatable {
    public var id: String
    public var command: String
    public init(id: String, command: String) {
        self.id = id
        self.command = command
    }
}

/// An agent/harness Zetty can launch in a fresh pane. Independent of
/// `AgentKind` (which drives detection): this catalog is purely about spawning.
public struct SpawnableAgent: Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// Compact label for tight chrome — the status-bar account chip and the
    /// Accounts list, where "Claude Code" and "Cursor Agent" are longer than the
    /// space deserves. Defaults to `displayName`.
    public let shortName: String
    public let defaultCommand: String

    /// Environment variable that relocates this harness's whole config — and
    /// therefore its credentials — into a directory of its own. `nil` means
    /// Zetty knows no verified isolation mechanism for it, so it cannot host
    /// accounts. Adding one later is this single line.
    public let configDirEnvVar: String?

    /// Where the harness keeps that config when the variable is unset, relative
    /// to home. This is what the "Default" account means, and what an account
    /// directory is forbidden from pointing at.
    public let defaultConfigDirName: String?

    /// Command that starts an interactive sign-in in a pane.
    public let loginCommand: String?

    /// Arguments that report who this config directory is signed in as, and how
    /// to read the answer. nil = Zetty can't probe this agent's identity.
    public let statusArguments: [String]?
    public let statusFormat: AuthStatusFormat?

    public init(
        id: String,
        displayName: String,
        defaultCommand: String,
        shortName: String? = nil,
        configDirEnvVar: String? = nil,
        defaultConfigDirName: String? = nil,
        loginCommand: String? = nil,
        statusArguments: [String]? = nil,
        statusFormat: AuthStatusFormat? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName ?? displayName
        self.defaultCommand = defaultCommand
        self.configDirEnvVar = configDirEnvVar
        self.defaultConfigDirName = defaultConfigDirName
        self.loginCommand = loginCommand
        self.statusArguments = statusArguments
        self.statusFormat = statusFormat
    }

    public static let catalog: [SpawnableAgent] = [
        .init(id: "claude",   displayName: "Claude Code",  defaultCommand: "claude",
              shortName: "Claude",
              configDirEnvVar: "CLAUDE_CONFIG_DIR",
              defaultConfigDirName: ".claude",
              loginCommand: "claude auth login",
              statusArguments: ["auth", "status", "--json"],
              statusFormat: .claudeJSON),
        // Codex keeps credentials in `auth.json` INSIDE its config dir rather
        // than the Keychain, so relocating the directory isolates the login
        // outright. Its status output is prose ("Logged in using ChatGPT"), not
        // JSON, so it can report whether an account is signed in but not who as.
        .init(id: "codex",    displayName: "Codex",        defaultCommand: "codex",
              configDirEnvVar: "CODEX_HOME",
              defaultConfigDirName: ".codex",
              loginCommand: "codex login",
              statusArguments: ["login", "status"],
              statusFormat: .plainText),
        .init(id: "hermes",   displayName: "Hermes",       defaultCommand: "hermes"),
        .init(id: "gemini",   displayName: "Gemini",       defaultCommand: "gemini"),
        .init(id: "opencode", displayName: "opencode",     defaultCommand: "opencode"),
        .init(id: "pi",       displayName: "Pi",           defaultCommand: "pi"),
        .init(id: "cursor",   displayName: "Cursor Agent", defaultCommand: "cursor-agent",
              shortName: "Cursor"),
    ]

    /// Catalog entries that can host accounts.
    public static var accountCapable: [SpawnableAgent] {
        catalog.filter { $0.configDirEnvVar != nil }
    }

    public static func byID(_ id: String) -> SpawnableAgent? {
        catalog.first { $0.id == id }
    }

    /// Effective enabled agents: each stored `ProjectAgent` whose id is in the
    /// catalog, paired with its command (stored command, or the catalog default
    /// when blank). Catalog order is preserved; unknown ids are dropped.
    public static func resolve(_ agents: [ProjectAgent]?) -> [ResolvedSpawnAgent] {
        guard let agents, !agents.isEmpty else { return [] }
        var commandByID: [String: String] = [:]
        for entry in agents where commandByID[entry.id] == nil {
            commandByID[entry.id] = entry.command
        }
        return catalog.compactMap { agent in
            guard let raw = commandByID[agent.id] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return ResolvedSpawnAgent(agent: agent, command: trimmed.isEmpty ? agent.defaultCommand : trimmed)
        }
    }
}

/// A catalog agent resolved with the command to actually run.
public struct ResolvedSpawnAgent: Sendable, Equatable {
    public let agent: SpawnableAgent
    public let command: String
    public init(agent: SpawnableAgent, command: String) {
        self.agent = agent
        self.command = command
    }
}

/// A project's agent-chooser configuration: which agents to offer, and whether
/// the new-pane chooser prompt is enabled at all.
public struct AgentSpawnConfig: Sendable, Equatable {
    public let agents: [ResolvedSpawnAgent]
    public let promptOnNewPane: Bool

    public init(agents: [ResolvedSpawnAgent], promptOnNewPane: Bool) {
        self.agents = agents
        self.promptOnNewPane = promptOnNewPane
    }

    /// No agents and no prompt.
    public static let disabled = AgentSpawnConfig(agents: [], promptOnNewPane: false)
}

extension SpawnableAgent {
    /// Builds a chooser config from stored per-project fields: the resolved
    /// enabled agents plus whether the prompt should show.
    public static func spawnConfig(agents: [ProjectAgent]?, promptOnNewPane: Bool) -> AgentSpawnConfig {
        AgentSpawnConfig(agents: resolve(agents), promptOnNewPane: promptOnNewPane)
    }
}
