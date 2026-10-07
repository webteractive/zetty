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
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    private static func url(agent: AgentKind, session: AgentSession,
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
