import Foundation

/// Reads a harness's OWN session store to recover the session id of a pane
/// whose hooks never reported one.
///
/// Hooks are the exact source (they name the pane), but they only fire when the
/// agent does something: a Codex pane that hasn't finished a turn emits
/// nothing, and neither does an agent that was already running before Zetty's
/// hooks were installed. Without a second source, restart recovery restores
/// those panes' screens and resumes nothing — which is the whole point of the
/// feature for a long-running agent.
///
/// Every function here is pure: paths and file CONTENTS come from the App layer
/// (`AgentSessionLookup`), which is the only side that touches the filesystem.
public enum AgentSessionStore {

    // MARK: - Claude Code

    /// Claude keeps one transcript per session at
    /// `~/.claude/projects/<slug>/<session-id>.jsonl`, where `<slug>` is the
    /// working directory with every non-alphanumeric character replaced by `-`
    /// (so `/Users/g/NL Generator` → `-Users-g-NL-Generator`).
    ///
    /// The rule is undocumented, so it is treated as a guess that must be
    /// CONFIRMED: the caller validates a candidate transcript by reading the
    /// `cwd` it recorded (`cwd(fromTranscriptLine:)`) and drops it on a
    /// mismatch. Validated against 48 real project directories with no
    /// mismatch; a future change to Claude's mapping degrades to "no fallback
    /// id" rather than to a wrong resume.
    public static func claudeProjectSlug(forCwd cwd: String) -> String {
        String(cwd.map { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber) ? ch : "-"
        })
    }

    /// The session id a transcript file name carries (`<uuid>.jsonl`), or nil
    /// when the name isn't a transcript or the id isn't shell-safe.
    public static func sessionID(fromTranscriptFileName name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let id = String(name.dropLast(".jsonl".count))
        guard AgentEvent.isValidSessionID(id) else { return nil }
        return id
    }

    /// The `cwd` a transcript line records, for confirming a slug guess. Only
    /// some line types carry one, so the caller scans a bounded number of
    /// lines.
    public static func cwd(fromTranscriptLine line: String) -> String? {
        jsonObject(from: line)?["cwd"] as? String
    }

    // MARK: - Codex

    /// Codex keeps rollouts at
    /// `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<timestamp>-<id>.jsonl`.
    /// The path does NOT encode the working directory, so a pane is matched by
    /// reading the first line, whose `payload` carries both `id` and `cwd`.
    ///
    /// (`codex resume --last` is deliberately not used: it picks the most
    /// recent session GLOBALLY, not within a directory, so with two Codex
    /// panes it would resume one pane's conversation into the other.)
    public static func codexRollout(fromFirstLine line: String) -> (id: String, cwd: String)? {
        guard let payload = jsonObject(from: line)?["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let cwd = payload["cwd"] as? String,
              AgentEvent.isValidSessionID(id), !cwd.isEmpty
        else { return nil }
        return (id, cwd)
    }

    // MARK: - Assignment

    /// Hands `candidates` (newest first) to `panes` (in the caller's order),
    /// one each, skipping ids already claimed elsewhere.
    ///
    /// When several panes share one working directory the store cannot say
    /// which conversation belonged to which pane, so this returns the right
    /// SET of conversations, possibly permuted between those panes — chosen
    /// over resuming nothing, and never over resuming one conversation twice.
    /// `excluding` is what keeps a pane's hook-derived session from being
    /// handed to its neighbour as a guess.
    public static func assign(
        panes: [UUID],
        candidates: [String],
        excluding claimed: Set<String> = []
    ) -> [UUID: String] {
        var available = candidates.filter { !claimed.contains($0) }
        var result: [UUID: String] = [:]
        for pane in panes {
            guard !available.isEmpty else { break }
            result[pane] = available.removeFirst()
        }
        return result
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
