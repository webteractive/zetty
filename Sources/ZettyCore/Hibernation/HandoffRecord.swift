import Foundation

/// What a hibernated pane needs to come back, captured before anything is
/// asked of it: the agent is gone by the time the pane wakes.
public struct HandoffRecord: Codable, Equatable, Sendable {
    public let surface: UUID
    public let agent: AgentKind
    public let sessionID: String
    public let cwd: String
    /// The harness account the agent was running under, `@default` included.
    /// nil reads as the pane's spawn account.
    public let accountID: String?
    public let requestedAt: Date
    /// The project the handoff belongs to, by its `settingsKey`. A handoff
    /// outlives its pane: the project wakes as one pane, and the others wait
    /// to be started in a new tab or split, so the pane is no longer what
    /// owns it. Nil in a record written before this was kept, which is owned
    /// by its pane.
    ///
    /// The key, not the project's id: a `ProjectRuntime` is given a new id
    /// at every launch, and records filed under one were all swept as
    /// orphans by the next.
    public var project: String?
    /// What the conversation was called when it was put away, for the list
    /// it is picked from. The pane that showed it is gone by then.
    public var title: String?
    /// Set once the pane has been woken with a line still to be typed, as
    /// that line was chosen: a quit loses the line, and this is what types
    /// it again. Nil is a handoff still waiting to be picked.
    public var wake: HandoffWake.Choice?

    public init(surface: UUID, agent: AgentKind, sessionID: String, cwd: String,
                accountID: String?, requestedAt: Date, project: String? = nil, title: String? = nil,
                wake: HandoffWake.Choice? = nil) {
        self.surface = surface
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
        self.accountID = accountID
        self.requestedAt = requestedAt
        self.project = project
        self.title = title
        self.wake = wake
    }

    /// Whether this handoff is waiting to be picked in `project`, whose
    /// panes are `panes`: its own, or one of its panes' from before records
    /// named their project, and not already on its way back.
    public func isWaiting(in project: String, panes: Set<UUID>) -> Bool {
        guard wake == nil else { return false }
        return self.project.map { $0 == project } ?? panes.contains(surface)
    }

    /// The same handoff under a new id. A handoff is filed under the pane it
    /// came from; when that pane goes on to hold something else, the next
    /// hibernation would file a new handoff in its place.
    public func rekeyed() -> HandoffRecord {
        HandoffRecord(surface: UUID(), agent: agent, sessionID: sessionID, cwd: cwd, accountID: accountID,
                      requestedAt: requestedAt, project: project, title: title, wake: wake)
    }

    /// "Claude · Fix the importer": whose it is and what it was called.
    ///
    /// A title taken off a pane starts with whatever the harness was
    /// drawing in front of it (`✳ Release notes`, a spinner frame), and one
    /// taken off the transcript does not. Listed together they looked like
    /// two kinds of thing, so the lead-in goes.
    public var label: String {
        let name = (title ?? "").drop { !$0.isLetter && !$0.isNumber }
        return name.isEmpty ? agent.displayName : "\(agent.displayName) · \(name)"
    }
}

/// `~/.zetty/handoffs/<SURFACE-UUID>.json`: which conversation a hibernated
/// pane resumes, and under which login. The handoff itself is the compacted
/// conversation, in the harness's own store.
public enum HandoffPaths {
    public static func directory(home: String) -> String { "\(home)/.zetty/handoffs" }

    public static func record(for surface: UUID, home: String) -> String {
        "\(directory(home: home))/\(surface.uuidString).json"
    }

    public static func surfaceID(fromFileName name: String) -> UUID? {
        UUID(uuidString: (name as NSString).deletingPathExtension)
    }
}

public enum HandoffPolicy {
    /// Past this an AUTOMATIC hibernate asks for no handoff: otherwise the
    /// first `hibernate-after` pass after the update would have every stale
    /// conversation compacted in turn, each a model turn.
    public static let handoffWithin: TimeInterval = 7 * 86_400

    public static func writesHandoff(manual: Bool, agentQuietFor: TimeInterval?) -> Bool {
        manual || (agentQuietFor ?? 0) <= handoffWithin
    }
}
