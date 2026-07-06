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
    public let defaultCommand: String

    public init(id: String, displayName: String, defaultCommand: String) {
        self.id = id
        self.displayName = displayName
        self.defaultCommand = defaultCommand
    }

    public static let catalog: [SpawnableAgent] = [
        .init(id: "claude",   displayName: "Claude Code",  defaultCommand: "claude"),
        .init(id: "codex",    displayName: "Codex",        defaultCommand: "codex"),
        .init(id: "hermes",   displayName: "Hermes",       defaultCommand: "hermes"),
        .init(id: "gemini",   displayName: "Gemini",       defaultCommand: "gemini"),
        .init(id: "opencode", displayName: "opencode",     defaultCommand: "opencode"),
        .init(id: "pi",       displayName: "Pi",           defaultCommand: "pi"),
        .init(id: "cursor",   displayName: "Cursor Agent", defaultCommand: "cursor-agent"),
    ]

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
