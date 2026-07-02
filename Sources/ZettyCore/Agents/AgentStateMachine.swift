import Foundation

public enum AgentStateMachine {
    /// Output more recent than this many seconds counts as active ("running").
    static let recentWindow: TimeInterval = 0.75

    public static func reduce(previous: AgentState, observation o: AgentObservation) -> AgentState {
        // Rule 1: no agent present clears everything.
        guard let descriptor = o.descriptor else {
            return AgentState(kind: nil, status: nil)
        }
        let kind = descriptor.kind

        // Rule 2a: an explicit hook event wins.
        if let hook = o.hookEvent {
            return AgentState(kind: kind, status: hook.asStatus)
        }

        let hasRecentOutput: Bool = {
            guard let last = o.lastOutputAt else { return false }
            return o.now - last <= recentWindow
        }()
        let isSilentBeyondIdle: Bool = {
            guard let last = o.lastOutputAt else { return true }
            return o.now - last >= descriptor.idleAfter
        }()

        // Rule 3: non-hook agents can never be needsAttention from heuristics.
        if descriptor.honorsHooks {
            // Rule 2b: attention is sticky until fresh output arrives.
            if previous.status == .needsAttention, !hasRecentOutput {
                return AgentState(kind: kind, status: .needsAttention)
            }
        }

        // Rule 2c: derive from activity.
        let status: AgentStatus
        if hasRecentOutput {
            status = .running
        } else if isSilentBeyondIdle {
            status = .idle
        } else {
            // Between recentWindow and idleAfter: hold previous non-attention status, default idle.
            let prior = previous.status
            status = (prior == .running || prior == .idle) ? prior! : .idle
        }
        return AgentState(kind: kind, status: status)
    }
}

private extension HookEvent {
    var asStatus: AgentStatus {
        switch self {
        case .running: return .running
        case .idle: return .idle
        case .needsAttention: return .needsAttention
        }
    }
}
