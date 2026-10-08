import Foundation
import ZettyCore

/// Where a session's transcript lives, for its modification date: the one
/// activity signal that survives a relaunch, and that an agent produces with
/// nobody looking. Blocking file IO — call off-main.
enum AgentTranscript {

    static func modificationDate(agent: AgentKind, session: AgentSession,
                                 configDirectory: String?) -> Date? {
        guard let url = url(agent: agent, session: session, configDirectory: configDirectory)
        else { return nil }
        // Claude runs subagents in its own process and writes each one's
        // transcript beside the session's, in `<session>/subagents/`. One
        // still working after the main turn ended shows nowhere else: the
        // hooks say idle and there is no child process to see.
        let subagents = url.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        let files = [url] + ((try? FileManager.default.contentsOfDirectory(
            at: subagents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        return files.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
    }

    /// Whether a transcript shows the agent having replied
    /// (`HandoffConversation.hasReply`): a conversation worth handing off.
    /// Blocking — call off-main.
    static func hasReply(at url: URL, agent: AgentKind) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: replyScanLimit) else { return false }
        // The first reply is near the top. A transcript too long to settle
        // within the cap holds a conversation whatever its opening says.
        return HandoffConversation.hasReply(agent: agent, transcript: String(decoding: head, as: UTF8.self))
            || head.count >= replyScanLimit
    }

    private static let replyScanLimit = 4 * 1024 * 1024

    /// Whether the conversation has grown since it was last compacted
    /// (`HandoffCompaction.needsCompaction`), read off the end of its
    /// transcript. Blocking — call off-main.
    static func needsCompaction(at url: URL, agent: AgentKind) -> Bool {
        guard let tail = tail(of: url) else { return true }
        return HandoffCompaction.needsCompaction(agent: agent, transcriptTail: tail)
    }

    /// What the harness called the conversation (`HandoffConversation.title`),
    /// or nil. Blocking — call off-main.
    static func title(at url: URL, agent: AgentKind) -> String? {
        tail(of: url).flatMap { HandoffConversation.title(agent: agent, transcriptTail: $0) }
    }

    /// The end of a transcript, up to `replyScanLimit`.
    private static func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(replyScanLimit) ? size - UInt64(replyScanLimit) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let tail = try? handle.readToEnd() else { return nil }
        return String(decoding: tail, as: UTF8.self)
    }

    /// The session's transcript, or nil when it cannot be found, which is
    /// what a cleared Claude chat is until its first message. Blocking.
    static func url(agent: AgentKind, session: AgentSession,
                            configDirectory: String?) -> URL? {
        let fileManager = FileManager.default
        switch agent {
        case .claude:
            let root = root(configDirectory, defaultName: ".claude").appendingPathComponent("projects")
            let guess = root
                .appendingPathComponent(AgentSessionStore.claudeProjectSlug(forCwd: session.cwd))
                .appendingPathComponent("\(session.id).jsonl")
            if fileManager.fileExists(atPath: guess.path) { return guess }
            // The slug rule is undocumented, and a session can be resumed
            // from another directory: fall back to the file name, which IS
            // the id.
            for slug in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
                let candidate = root.appendingPathComponent(slug)
                    .appendingPathComponent("\(session.id).jsonl")
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil
        case .codex:
            // sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl
            let root = root(configDirectory, defaultName: ".codex").appendingPathComponent("sessions")
            let suffix = "-\(session.id).jsonl"
            guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)
            else { return nil }
            var seen = 0
            for case let url as URL in walker {
                seen += 1
                if seen > scanLimit { return nil }
                if url.lastPathComponent.hasSuffix(suffix) { return url }
            }
            return nil
        default:
            return nil
        }
    }

    /// A bound on the Codex walk, not an expectation: its store holds
    /// hundreds of files, not tens of thousands.
    private static let scanLimit = 20_000

    private static func root(_ configDirectory: String?, defaultName: String) -> URL {
        if let configDirectory {
            return URL(fileURLWithPath: (configDirectory as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(defaultName)
    }
}
