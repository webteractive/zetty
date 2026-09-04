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

    /// The 8-hex short id derived from a surface UUID — the session-name
    /// suffix, and the pane id the `zetty` CLI addresses.
    public static func shortID(for surfaceID: UUID) -> String {
        let hex = surfaceID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(8))
    }

    public static func sessionName(for surfaceID: UUID) -> String {
        namePrefix + shortID(for: surfaceID)
    }

    /// Printed after a restart snapshot is replayed, so the replayed screen is
    /// not mistaken for a live process (dim, one line).
    public static let restoreDivider = "── restored after restart ──"

    /// Contents of the generated scrollback-restore wrapper
    /// (`~/.zetty/scrollback-restore.sh`; the app layer writes it). Replays
    /// the session's full scrollback (attributes intact) into the surface as
    /// ordinary output, then execs the attach so no extra shell lingers.
    ///
    /// Two sources, chosen by the optional third argument: a restart-recovery
    /// snapshot file (the session is known dead — the file is printed, deleted,
    /// and followed by `restoreDivider`), otherwise `zmx history --vt` for the
    /// live session. `unset ZMX_SESSION` covers the inherited-session hazard
    /// (see `attachCommand`) for both zmx invocations. A missing session (new
    /// pane) prints nothing — stderr is suppressed — and attach creates it as
    /// before.
    public static let restoreScriptContents = """
    #!/bin/sh
    # Zetty scrollback restore (generated; do not edit — rewritten on launch).
    # $1 = zmx path, $2 = session name, $3 = optional restart snapshot file.
    unset ZMX_SESSION
    if [ -n "$3" ] && [ -f "$3" ]; then
      cat "$3"
      rm -f "$3"
      printf '\\033[2m\(restoreDivider)\\033[0m\\n'
    else
      "$1" history "$2" --vt 2>/dev/null
    fi
    exec "$1" attach "$2"
    """

    /// The ghostty `command` value that runs the pane inside its zmx session.
    /// zmx attach creates the session (running the user's shell) if missing.
    ///
    /// With a `restoreScriptPath`, the pane instead runs the wrapper script,
    /// which replays the session's scrollback history before attaching. The
    /// invocation is plain space-separated tokens — ghostty's `command`
    /// parser can't be relied on for quote grouping, so nothing may need
    /// quoting (paths with spaces are already unsupported by the bare form).
    /// `snapshotPath` (restart recovery) is appended as a fourth token and is
    /// subject to the same no-spaces rule.
    ///
    /// ZMX_SESSION is unset first (by `env -u` here, by the script there):
    /// when Zetty itself was launched from a zmx-backed terminal (e.g.
    /// Supacode), every pane inherits that variable, and `zmx attach` run
    /// "inside" a session kills it instead of attaching the target (or
    /// errors out if it's already gone).
    public static func attachCommand(
        zmxPath: String,
        surfaceID: UUID,
        restoreScriptPath: String? = nil,
        snapshotPath: String? = nil
    ) -> String {
        let session = sessionName(for: surfaceID)
        guard let script = restoreScriptPath else {
            return "/usr/bin/env -u ZMX_SESSION \(zmxPath) attach \(session)"
        }
        var command = "/bin/sh \(script) \(zmxPath) \(session)"
        // Fourth plain token; present only for a surface the recovery manifest
        // named, so an ordinary launch renders exactly the command it did before.
        if let snapshotPath { command += " \(snapshotPath)" }
        return command
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

    /// Parses `zmx list --short` output into session names, keeping only ours.
    /// Tolerates blank lines and ignores foreign sessions.
    public static func zettySessions(fromList output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(namePrefix) }
    }

    /// Sessions in `existing` that no live surface owns — candidates for
    /// cleanup ("orphans"). `liveSurfaceIDs` are all surfaces across the
    /// whole workspace (every project/tab/pane).
    public static func orphans(existing: [String], liveSurfaceIDs: [UUID]) -> [String] {
        let owned = Set(liveSurfaceIDs.map(sessionName(for:)))
        return existing.filter { !owned.contains($0) }
    }

    /// Per-pane cwd file names (`<UUID>.cwd`, see `PaneCwdStore`) that no live
    /// surface owns — the file-side twin of `orphans(existing:liveSurfaceIDs:)`,
    /// so one reconciliation pass can clear both kinds of leftover.
    ///
    /// Anything that isn't a `<uuid>.cwd` name is left strictly alone: this
    /// drives deletion, so an unparseable name must never be treated as an
    /// orphan.
    public static func orphanCwdFiles(existing: [String], liveSurfaceIDs: [UUID]) -> [String] {
        let owned = Set(liveSurfaceIDs.map { $0.uuidString.lowercased() })
        return existing.filter { name in
            guard name.hasSuffix(cwdFileSuffix) else { return false }
            let stem = String(name.dropLast(cwdFileSuffix.count))
            guard UUID(uuidString: stem) != nil else { return false }
            return !owned.contains(stem.lowercased())
        }
    }

    public static let cwdFileSuffix = ".cwd"
}
