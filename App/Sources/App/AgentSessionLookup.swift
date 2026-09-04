import Foundation
import ZettyCore

/// Filesystem side of the restart-recovery fallback: finds the session id of a
/// pane whose hooks never reported one, by reading the harness's own session
/// store. Pure parsing and the assignment policy live in `AgentSessionStore`.
///
/// Runs inside the power-off budget, so every scan is bounded and nothing here
/// touches the main thread.
enum AgentSessionLookup {

    /// A pane that needs a session id: where it is, and what it is running.
    struct Target {
        let surface: UUID
        let cwd: String
        let agent: AgentKind
    }

    /// How many transcript lines to read while confirming a slug guess. The
    /// `cwd` appears within the first handful of entries; 40 is slack.
    private static let cwdProbeLines = 40

    /// How many Codex rollouts to open, newest first, before giving up. Its
    /// store holds hundreds of files and the path doesn't encode the working
    /// directory, so matching means reading first lines — bounded so a large
    /// history can't eat the shutdown budget.
    private static let codexScanLimit = 250

    /// Session ids for `targets`, read from each harness's own store.
    /// `claimed` are ids already known from hooks, which must not be handed to
    /// a different pane as a guess.
    static func fallbackSessions(for targets: [Target], claimed: Set<String>) -> [UUID: AgentSession] {
        guard !targets.isEmpty else { return [:] }
        var result: [UUID: AgentSession] = [:]

        // Grouped by directory: that is the granularity both stores offer, and
        // the granularity the ambiguity policy is written against.
        let byCwd = Dictionary(grouping: targets.filter { $0.agent == .claude }, by: \.cwd)
        for (cwd, panes) in byCwd {
            let ids = claudeSessionIDs(forCwd: cwd, limit: panes.count)
            for (surface, id) in AgentSessionStore.assign(
                panes: panes.map(\.surface), candidates: ids, excluding: claimed) {
                result[surface] = AgentSession(id: id, cwd: cwd)
            }
        }

        let codexByCwd = Dictionary(grouping: targets.filter { $0.agent == .codex }, by: \.cwd)
        if !codexByCwd.isEmpty {
            // How many ids each directory actually needs, so the scan can stop
            // as soon as every pane is covered instead of reading to its limit.
            let needed = codexByCwd.mapValues(\.count)
            let idsByCwd = codexSessionIDs(needed: needed)
            for (cwd, panes) in codexByCwd {
                for (surface, id) in AgentSessionStore.assign(
                    panes: panes.map(\.surface), candidates: idsByCwd[cwd] ?? [], excluding: claimed) {
                    result[surface] = AgentSession(id: id, cwd: cwd)
                }
            }
        }

        ZettyLog.lifecycle.log(
            "session store: \(result.count) of \(targets.count) pane(s) matched a stored session")
        return result
    }

    // MARK: - Claude Code

    /// Newest-first session ids recorded for `cwd`, each CONFIRMED to belong to
    /// that directory by the `cwd` inside the transcript — so a change to
    /// Claude's undocumented slug rule yields no fallback rather than a wrong
    /// resume.
    private static func claudeSessionIDs(forCwd cwd: String, limit: Int) -> [String] {
        let slug = AgentSessionStore.claudeProjectSlug(forCwd: cwd)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)", isDirectory: true)
        var found: [String] = []
        for url in newestFirst(in: directory) {
            guard let id = AgentSessionStore.sessionID(fromTranscriptFileName: url.lastPathComponent) else {
                continue
            }
            guard recordedCwd(inTranscript: url) == cwd else { continue }
            found.append(id)
            if found.count >= limit { break }
        }
        return found
    }

    /// The `cwd` a transcript claims, read from its first lines. nil when the
    /// file is unreadable or records none — which fails the confirmation.
    private static func recordedCwd(inTranscript url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // 64 KB covers far more than `cwdProbeLines` entries without reading a
        // multi-megabyte transcript to answer a one-field question.
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(cwdProbeLines) {
            if let cwd = AgentSessionStore.cwd(fromTranscriptLine: String(line)) { return cwd }
        }
        return nil
    }

    // MARK: - Codex

    /// Newest-first session ids per requested directory, from Codex's rollout
    /// store. One pass, newest file first, stopping as soon as every directory
    /// in `needed` has that many ids — or the scan limit is reached.
    private static func codexSessionIDs(needed: [String: Int]) -> [String: [String]] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        // Rollout names start with an ISO timestamp, and the tree is
        // <yyyy>/<mm>/<dd>, so a reverse lexicographic sort of the full paths
        // is chronological without a single stat call.
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        let files = walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.path > $1.path }

        var result: [String: [String]] = [:]
        var opened = 0
        for url in files {
            guard opened < codexScanLimit else { break }
            // Satisfied when every directory has as many ids as it has panes.
            if needed.allSatisfy({ (result[$0.key]?.count ?? 0) >= $0.value }) { break }
            opened += 1
            guard let line = firstLine(of: url),
                  let rollout = AgentSessionStore.codexRollout(fromFirstLine: line),
                  let want = needed[rollout.cwd] else { continue }
            var ids = result[rollout.cwd] ?? []
            guard ids.count < want, !ids.contains(rollout.id) else { continue }
            ids.append(rollout.id)
            result[rollout.cwd] = ids
        }
        return result
    }

    private static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // A rollout's first line is its metadata record; it can be long
        // (instructions are inlined), so allow a generous slice.
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
    }

    // MARK: - Shared

    /// Directory contents ordered newest modification first; empty when the
    /// directory is missing.
    private static func newestFirst(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (da ?? .distantPast) > (db ?? .distantPast)
        }
    }
}
