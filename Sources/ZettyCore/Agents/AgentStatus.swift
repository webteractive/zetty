import Foundation

public enum AgentStatus: String, Codable, Sendable {
    case running
    case idle
    case needsAttention
}

public enum HookEvent: String, Sendable, Equatable {
    case running
    case idle
    case needsAttention
}

/// The harness session a pane's agent is running, as its hooks reported it:
/// the id `claude --resume` / `codex resume` take, and the cwd the agent
/// itself reported (the pane's shell may live elsewhere). One value rather
/// than two fields so the id and its directory can never disagree.
public struct AgentSession: Sendable, Equatable {
    public let id: String
    public let cwd: String

    public init(id: String, cwd: String) {
        self.id = id
        self.cwd = cwd
    }
}

public struct AgentState: Sendable, Equatable {
    public var kind: AgentKind?
    public var status: AgentStatus?
    /// Last known harness session; kept across events that carry none,
    /// cleared with presence.
    public var session: AgentSession?

    public init(kind: AgentKind? = nil, status: AgentStatus? = nil, session: AgentSession? = nil) {
        self.kind = kind
        self.status = status
        self.session = session
    }
}

public struct AgentObservation: Sendable {
    public var descriptor: AgentDescriptor?
    public var lastOutputAt: TimeInterval?
    public var hookEvent: HookEvent?
    public var now: TimeInterval
    /// Non-nil only on a hook event that carried a session id.
    public var session: AgentSession?

    public init(descriptor: AgentDescriptor?, lastOutputAt: TimeInterval?, hookEvent: HookEvent?,
                now: TimeInterval, session: AgentSession? = nil) {
        self.descriptor = descriptor
        self.lastOutputAt = lastOutputAt
        self.hookEvent = hookEvent
        self.now = now
        self.session = session
    }
}
