import Foundation

/// What a desktop notification (OSC 9 / 777) from an agent pane means.
public enum TerminalNotificationMeaning: Equatable, Sendable {
    /// The agent is blocked on a decision: "needs you", with its own words.
    case decision(String)
    /// Anything else (a turn ended): a banner, never yellow.
    case finished(String)
    /// Not a state source (Claude: the mod and hooks label its notices).
    case noState
}

/// Sorts an agent's terminal notification into a decision or a finished turn
/// (spec 2026-11-14, section 7.1). The same sequence carries both — Codex
/// sends OSC 9 for an approval and at every turn end — and under "decisions
/// only" an unlabelled notice must not turn a pane yellow.
public enum TerminalNotification {

    /// How Codex words a decision, checked in Codex 0.157.1's binary
    /// ("Approval requested: …", "Approval requested by …", "Codex wants to
    /// edit …", "Question requested", "Implement this plan?"). Its turn-end
    /// notice is "Agent turn complete" or the agent's last message.
    public static let decisionPrefixes = ["Approval requested", "Codex wants to edit",
                                          "Question requested", "Implement this plan?"]

    public static func classify(title: String?, body: String?, agent: AgentKind?) -> TerminalNotificationMeaning {
        if agent == .claude { return .noState }
        let text = (nonEmpty(body) ?? nonEmpty(title) ?? "")
        if decisionPrefixes.contains(where: { text.hasPrefix($0) }) { return .decision(text) }
        return .finished(text)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
