import Foundation

/// A project on its way to being hibernated: its agents compact their
/// conversations FIRST, and it is put away only once every one of them has.
///
/// The other order (put away at once, hand off afterwards) left a window in
/// which waking found no handoff and quietly resumed the old conversation,
/// and a handoff that failed there was only ever seen as a pane waking into
/// a plain shell. Here a failure leaves the project awake, where it can be
/// seen.
///
/// A value type with no clock and no process, so the bookkeeping is testable.
public struct HibernationPreparation: Equatable, Sendable {

    public enum Outcome: Equatable, Sendable {
        /// Every agent has compacted: put the project away. These are the
        /// panes that come back by resuming.
        case putAway(Set<UUID>)
        /// This pane could not: the project stays awake.
        case leftAwake(failed: UUID)
    }

    /// Every pane the project had when it was asked to hibernate. One added
    /// or closed since is unexamined, and ends the attempt.
    public let panes: [UUID]
    /// `hibernate-after` asked, not a person: it gives way to the project
    /// being looked at again.
    public let isAutomatic: Bool
    public private(set) var awaiting: Set<UUID>
    public private(set) var compacted: Set<UUID> = []

    public init(panes: [UUID], awaiting: Set<UUID>, isAutomatic: Bool) {
        self.panes = panes
        self.awaiting = awaiting
        self.isAutomatic = isAutomatic
    }

    /// Whether this pane's handoff is still being written, or is written and
    /// waiting on the others.
    public func isWriting(_ surface: UUID) -> Bool {
        awaiting.contains(surface) || compacted.contains(surface)
    }

    public func describes(_ current: [UUID]) -> Bool { Set(current) == Set(panes) }

    /// A pane is done, one way or another. Nil while others are still out,
    /// and for a pane that was not being waited on.
    public mutating func finish(_ surface: UUID, _ result: HandoffCompaction.Result) -> Outcome? {
        guard awaiting.remove(surface) != nil else { return nil }
        switch result {
        case .failed:    return .leftAwake(failed: surface)
        case .compacted: compacted.insert(surface)
        case .skipped:   break      // nothing to hand off, and no failure
        }
        return awaiting.isEmpty ? .putAway(compacted) : nil
    }
}

/// Whether a transcript holds a conversation worth handing off.
public enum HandoffConversation {
    /// What the harness itself called the conversation, from the end of its
    /// transcript: Claude writes `{"type":"ai-title","aiTitle":…}` and
    /// rewrites it as the work moves on, so the last one counts. Codex
    /// records none. This names a handoff whose pane was never on screen
    /// and so never reported a title: three such handoffs in one project
    /// were listed as "Claude", "Claude", "Claude".
    public static func title(agent: AgentKind, transcriptTail: String) -> String? {
        guard agent == .claude else { return nil }
        for line in transcriptTail.split(whereSeparator: \.isNewline).reversed()
        where line.contains("ai-title") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "ai-title",
                  let title = (object["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            return title
        }
        return nil
    }

    /// True once the agent has replied at least once. A cleared or brand-new
    /// chat has a session id and nothing to summarise: asked to compact, it
    /// answers that there is nothing to, which would otherwise read as a
    /// handoff that could not be written.
    ///
    /// The agent's reply is the sign, not the person's message: after a
    /// `/clear` a Claude transcript opens with `user` lines that are the
    /// command's own output. Read off claude 2.1.293 and codex 0.161.0:
    /// Claude writes `{"type":"assistant",…}`, Codex
    /// `{"type":"response_item","payload":{"role":"assistant",…}}`.
    public static func hasReply(agent: AgentKind, transcript: String) -> Bool {
        transcript.split(whereSeparator: \.isNewline).contains { line in
            // Most lines never mention the word; only those are parsed.
            guard line.contains("assistant"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { return false }
            switch agent {
            case .claude:
                return object["type"] as? String == "assistant"
            case .codex:
                return object["type"] as? String == "response_item"
                    && (object["payload"] as? [String: Any])?["role"] as? String == "assistant"
            default:
                return false
            }
        }
    }
}
