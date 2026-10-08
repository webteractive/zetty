import Foundation

/// How a pane's agent leaves its handoff: it compacts its OWN conversation,
/// in its own chat, where the person can watch it happen. The compacted
/// conversation is the handoff, and waking resumes it.
///
/// This replaced a headless fork (`claude -p --resume … --fork-session`) that
/// wrote the handoff out of sight (Glen, 2026-10-08). The fork was invisible,
/// was a cold read of the whole transcript in a second process, and left a
/// file that a fresh agent then had to be pointed at. Compacting needs none
/// of that: no second process, no file, no account to run it under.
/// Read off claude 2.1.294 and codex 0.161.0.
public enum HandoffCompaction {

    /// Past this the pane is given up on and its project is left awake.
    public static let timeout: TimeInterval = 300

    public enum Result: Equatable, Sendable {
        case compacted
        /// Nothing to hand off: a cleared or brand-new chat. Not a failure.
        case skipped
        /// Why the project is left awake, phrased to follow "Pane x: ".
        case failed(String)
    }

    public static func supports(_ kind: AgentKind) -> Bool { line(for: kind) != nil }

    /// What is typed into the agent's prompt box, without the Enter. One
    /// line: a newline in it would be read as submitting half of it.
    public static func line(for agent: AgentKind) -> String? {
        switch agent {
        case .claude: return "/compact \(instructions)"
        // Codex's `/compact` takes no instructions.
        case .codex:  return "/compact"
        default:      return nil
        }
    }

    /// Kept short: Claude folds a long paste into a `[Pasted text]` chip,
    /// which a slash command would then take as its whole argument.
    static let instructions = "Write this summary as a handoff for a fresh agent that picks this work up "
        + "later and remembers nothing: the goal; what is done; the current state, naming every file that "
        + "matters by its full path; decisions made and why; open questions; the next steps; and anything "
        + "the person asked you to remember. Leave out passwords, keys, tokens and other secrets."

    /// The first message of the resumed conversation. One line as well: it
    /// is an argument on a shell line.
    public static let wakeLine = "This project was hibernated and you are picking it up again from the "
        + "summary above. Tell the person in a sentence or two where things stand, then wait for them."

    /// Whether what a transcript gained since the request shows the
    /// compaction finished. Claude writes `{"type":"system","subtype":
    /// "compact_boundary"}` and Codex `{"type":"compacted"}`; both land as
    /// the harness prints that it is done.
    public static func hasCompacted(agent: AgentKind, appended: String) -> Bool {
        appended.split(whereSeparator: \.isNewline).contains { isMarker($0, agent: agent) }
    }

    /// Whether a conversation has anything to compact: false when it was
    /// compacted and the agent has not replied since. That is a project
    /// woken and put away again with nothing said in between, and it is
    /// already a handoff. Asked anyway, Claude answers "Not enough messages
    /// to compact" and writes no marker, which read as a failure and left
    /// the project awake.
    ///
    /// `transcriptTail` is the end of the transcript; a marker further back
    /// than it reaches has plenty after it.
    public static func needsCompaction(agent: AgentKind, transcriptTail: String) -> Bool {
        let lines = transcriptTail.split(whereSeparator: \.isNewline)
        guard let marker = lines.lastIndex(where: { isMarker($0, agent: agent) }) else { return true }
        return HandoffConversation.hasReply(
            agent: agent, transcript: lines[lines.index(after: marker)...].joined(separator: "\n"))
    }

    private static func isMarker(_ line: Substring, agent: AgentKind) -> Bool {
        guard line.contains("compact"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return false }
        switch agent {
        case .claude:
            return object["type"] as? String == "system"
                && object["subtype"] as? String == "compact_boundary"
        case .codex:
            return object["type"] as? String == "compacted"
        default:
            return false
        }
    }
}
