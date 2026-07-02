import Foundation

public struct AgentDescriptor: Sendable, Equatable {
    public let kind: AgentKind
    public let displayName: String
    public let binaryNames: [String]
    public let honorsHooks: Bool
    public let idleAfter: TimeInterval

    public init(
        kind: AgentKind,
        displayName: String,
        binaryNames: [String],
        honorsHooks: Bool,
        idleAfter: TimeInterval
    ) {
        self.kind = kind
        self.displayName = displayName
        self.binaryNames = binaryNames
        self.honorsHooks = honorsHooks
        self.idleAfter = idleAfter
    }
}
