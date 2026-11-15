import Foundation

/// One timestamped claim about what a pane's agent is doing, from any source:
/// the Claude Code mod's snapshot, a harness hook event, or a terminal signal.
/// `AgentStatusBoard` folds them per pane, newest first.
public struct AgentReport: Sendable, Equatable {

    /// Where a report came from. The raw value orders a tie: two reports
    /// with the same `at` go to the higher source (the mod, Glen 2026-11-14).
    public enum Source: Int, Sendable, Comparable {
        case hook = 0
        case terminal = 1
        case mod = 2

        public static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum State: String, Sendable {
        case running
        case idle
        case needsAttention
        case ended
    }

    public var source: Source
    public var agent: AgentKind
    public var state: State
    /// When it happened, in epoch seconds. 0 means unknown (a hook line
    /// written before events carried `ts`) and sorts as the oldest.
    public var at: TimeInterval
    public var session: AgentSession?
    /// What the agent asked or said, when the source carried it.
    public var message: String?

    public init(source: Source, agent: AgentKind, state: State, at: TimeInterval,
                session: AgentSession? = nil, message: String? = nil) {
        self.source = source
        self.agent = agent
        self.state = state
        self.at = at
        self.session = session
        self.message = message
    }

    /// True when this report should replace `other` as a pane's latest.
    func supersedes(_ other: AgentReport?) -> Bool {
        guard let other else { return true }
        return at > other.at || (at == other.at && source > other.source)
    }
}

/// What applying one report (or a probe reading) did to a pane.
public struct AgentApplyResult: Sendable, Equatable {
    public var accepted: Bool
    /// The status before this report.
    public var previous: AgentStatus?
    /// The state after it (unchanged when not accepted).
    public var state: AgentState
    /// Post "needs you" now: sound, banner, and reopen the inbox entry.
    public var raisedAttention: Bool
    /// Post the finished-turn banner now.
    public var finished: Bool

    public init(accepted: Bool, previous: AgentStatus?, state: AgentState,
                raisedAttention: Bool = false, finished: Bool = false) {
        self.accepted = accepted
        self.previous = previous
        self.state = state
        self.raisedAttention = raisedAttention
        self.finished = finished
    }

    /// The shown status moved (or presence came or went).
    public var changedStatus: Bool { previous != state.status }
}
