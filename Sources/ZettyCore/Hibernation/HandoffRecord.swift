import Foundation

/// What a hibernated pane's handoff needs, captured BEFORE the teardown: the
/// agent is gone by the time the fork runs, and by the time the pane wakes.
public struct HandoffRecord: Codable, Equatable, Sendable {
    public let surface: UUID
    public let agent: AgentKind
    public let sessionID: String
    public let cwd: String
    /// The harness account the agent was running under, `@default` included.
    /// nil reads as the pane's spawn account.
    public let accountID: String?
    public let requestedAt: Date

    public init(surface: UUID, agent: AgentKind, sessionID: String, cwd: String,
                accountID: String?, requestedAt: Date) {
        self.surface = surface
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
        self.accountID = accountID
        self.requestedAt = requestedAt
    }
}

/// `~/.zetty/handoffs/<SURFACE-UUID>.json` (the record) and `.md` (the wake
/// file: wake line plus handoff). Outside every repo, so nothing shows in
/// anyone's `git status`.
public enum HandoffPaths {
    public static func directory(home: String) -> String { "\(home)/.zetty/handoffs" }

    public static func record(for surface: UUID, home: String) -> String {
        "\(directory(home: home))/\(surface.uuidString).json"
    }

    public static func handoff(for surface: UUID, home: String) -> String {
        "\(directory(home: home))/\(surface.uuidString).md"
    }

    public static func surfaceID(fromFileName name: String) -> UUID? {
        UUID(uuidString: (name as NSString).deletingPathExtension)
    }
}

public enum HandoffPolicy {
    /// Past this an AUTOMATIC hibernate writes no handoff: otherwise the first
    /// `hibernate-after` pass after the update would cold-read every stale
    /// transcript in turn.
    public static let handoffWithin: TimeInterval = 7 * 86_400

    public static func writesHandoff(manual: Bool, agentQuietFor: TimeInterval?) -> Bool {
        manual || (agentQuietFor ?? 0) <= handoffWithin
    }
}
