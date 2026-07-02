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

public struct AgentState: Sendable, Equatable {
    public var kind: AgentKind?
    public var status: AgentStatus?

    public init(kind: AgentKind? = nil, status: AgentStatus? = nil) {
        self.kind = kind
        self.status = status
    }
}

public struct AgentObservation: Sendable {
    public var descriptor: AgentDescriptor?
    public var lastOutputAt: TimeInterval?
    public var hookEvent: HookEvent?
    public var now: TimeInterval

    public init(descriptor: AgentDescriptor?, lastOutputAt: TimeInterval?, hookEvent: HookEvent?, now: TimeInterval) {
        self.descriptor = descriptor
        self.lastOutputAt = lastOutputAt
        self.hookEvent = hookEvent
        self.now = now
    }
}
