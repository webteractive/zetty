import Foundation

/// What OSC 9;4 progress may say about an agent pane.
public enum TerminalProgressPolicy {
    /// The report a progress change makes, or nil for none. A set means
    /// running and a clear ends a running turn, but neither moves a pane out
    /// of "needs you": Claude may clear or re-send its progress while it waits
    /// to ask, and the mod or a hook already raised that yellow.
    public static func report(active: Bool, current: AgentStatus?) -> AgentReport.State? {
        if current == .needsAttention { return nil }
        if active { return .running }
        return current == .running ? .idle : nil
    }
}

/// What a key typed into an agent pane says about it.
public enum PromptAnswerPolicy {
    /// Agents whose own reports never move a pane off "needs you" once you
    /// answer: Codex's only hook is the turn's end, and it sends no progress
    /// (0.157.1), so an approved pane stayed yellow until the turn ended
    /// (release review, 2026-11-20). Claude's and Hermes's hooks say when
    /// they move on.
    static let answeredByKeys: Set<AgentKind> = [.codex]

    /// `.running` when a key reached a pane waiting on one of those agents:
    /// the key is the answer. nil otherwise.
    public static func report(agent: AgentKind?, current: AgentStatus?) -> AgentReport.State? {
        guard let agent, answeredByKeys.contains(agent), current == .needsAttention else { return nil }
        return .running
    }

    /// Whether `chord` is one the pane's program receives, so it can answer.
    /// ⌘ chords belong to the menus (⌘C copying the command Codex wants
    /// approved turned the pane green; review of 70c34a5, 2026-11-20).
    public static func answers(_ chord: KeyChord) -> Bool {
        !chord.modifiers.contains(.cmd)
    }
}

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
