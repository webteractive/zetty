import Foundation

/// Pure helpers for zmx-backed session preservation.
///
/// One zmx session per pane, named from the surface's persistent UUID so a
/// relaunch (which restores the same UUIDs from `workspace.json`) reattaches
/// each pane to its own still-running session. All process IO lives in the app
/// layer; this type only builds names/commands and parses output.
public enum SessionPersistence {

    /// Session names are `zetty-<first 8 uuid hex chars, lowercased>`.
    public static let namePrefix = "zetty-"

    /// The pre-rename prefix. zmx cannot rename sessions, so sessions created
    /// before the Zetty rebrand keep this name; attach and orphan logic treat
    /// both prefixes as ours until the legacy sessions age out.
    public static let legacyNamePrefix = "quertty-"

    /// The 8-hex short id derived from a surface UUID — the session-name
    /// suffix, and the pane id the `zetty` CLI addresses.
    public static func shortID(for surfaceID: UUID) -> String {
        let hex = surfaceID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(8))
    }

    public static func sessionName(for surfaceID: UUID) -> String {
        namePrefix + shortID(for: surfaceID)
    }

    public static func legacySessionName(for surfaceID: UUID) -> String {
        legacyNamePrefix + shortID(for: surfaceID)
    }

    /// The ghostty `command` value that runs the pane inside its zmx session.
    /// zmx attach creates the session (running the user's shell) if missing.
    /// When only the pane's pre-rename (`quertty-`) session is alive in
    /// `existingSessions`, it is reattached instead of minting a new one.
    ///
    /// ZMX_SESSION is unset first: when Zetty itself was launched from a
    /// zmx-backed terminal (e.g. Supacode), every pane inherits that variable,
    /// and `zmx attach` run "inside" a session kills it instead of attaching
    /// the target (or errors out if it's already gone).
    public static func attachCommand(
        zmxPath: String, surfaceID: UUID, existingSessions: Set<String> = []
    ) -> String {
        let name = sessionName(for: surfaceID)
        let legacy = legacySessionName(for: surfaceID)
        let target = (!existingSessions.contains(name) && existingSessions.contains(legacy)) ? legacy : name
        return "/usr/bin/env -u ZMX_SESSION \(zmxPath) attach \(target)"
    }

    /// Parses full `zmx list` output into session name → root pid, for
    /// foreground-process resolution. Unparseable lines are skipped.
    public static func sessionPIDs(fromList output: String) -> [String: Int32] {
        var pids: [String: Int32] = [:]
        for line in output.split(separator: "\n") {
            var name: String?
            var pid: Int32?
            for token in line.split(whereSeparator: { $0 == "\t" || $0 == " " }) {
                if token.hasPrefix("name=") { name = String(token.dropFirst(5)) }
                if token.hasPrefix("pid=") { pid = Int32(token.dropFirst(4)) }
            }
            if let name, let pid { pids[name] = pid }
        }
        return pids
    }

    /// Parses `zmx list --short` output into session names, keeping only ours
    /// (both prefixes). Tolerates blank lines and ignores foreign sessions.
    public static func zettySessions(fromList output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(namePrefix) || $0.hasPrefix(legacyNamePrefix) }
    }

    /// Sessions in `existing` that no live surface owns — candidates for
    /// cleanup ("orphans"). `liveSurfaceIDs` are all surfaces across the
    /// whole workspace (every project/tab/pane); each owns its session under
    /// either prefix.
    public static func orphans(existing: [String], liveSurfaceIDs: [UUID]) -> [String] {
        let owned = Set(liveSurfaceIDs.map(sessionName(for:)))
            .union(liveSurfaceIDs.map(legacySessionName(for:)))
        return existing.filter { !owned.contains($0) }
    }
}
