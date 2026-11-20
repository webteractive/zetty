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

    /// The wrapper's file name, in `~/.zetty/`.
    public static let restoreScriptName = "scrollback-restore.sh"

    /// Ends a wrapper's `zmx attach` so the wrapper repaints the pane: it
    /// clears the screen and scrollback, replays `zmx history --vt` and
    /// attaches again (`RemoteSizeHandoff`). Only the wrapper's own attach
    /// may get it (`ZmxAttachProcesses.repaintablePIDs`).
    public static let repaintSignal = SIGUSR1

    /// Contents of the generated scrollback-restore wrapper
    /// (`~/.zetty/scrollback-restore.sh`; the app layer writes it). Replays
    /// the session's full scrollback (attributes intact) into the surface as
    /// ordinary output, then attaches. It stays as the attach's parent, so an
    /// attach ended by `repaintSignal` can be restarted from a clean screen;
    /// any other exit ends the wrapper with the attach's status, as the old
    /// `exec` did. A repaint re-checks the session first, because `zmx attach`
    /// would create a missing one.
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
    export \(noDetachKey)
    if [ -n "$3" ] && [ -f "$3" ]; then
      cat "$3"
      rm -f "$3"
      printf '\\033[2m\(restoreDivider)\\033[0m\\n'
    else
      "$1" history "$2" --vt 2>/dev/null
    fi
    while :; do
      "$1" attach "$2"
      status=$?
      [ "$status" = \(128 + repaintSignal) ] || exit "$status"
      stty sane 2>/dev/null
      if replay=\(fetchReplay); then
        printf '\(clearScreenEscaped)%s' "${replay%x}"
      else
        "$1" list 2>/dev/null | grep -Fq "name=$2\t" || exit 0
        printf '\(clearScreenEscaped)'
      fi
    done
    """

    /// Turns off zmx's own detach key, Ctrl+\\, for an attach Zetty runs.
    /// A detach ends the pane's command while the session lives on, so the
    /// pane shows "Process exited" over it, and the next key closes the
    /// pane. Inside a pane Ctrl+\\ belongs to the program (SIGQUIT, an
    /// editor binding), and Zetty detaches through its own lifecycle. zmx
    /// 0.8.1 and 1.0.1 read it; a session still run by 0.6.0 keeps the key
    /// until it ends (2026-11-20).
    static let noDetachKey = "ZMX_NO_DETACH_KEY=1"

    /// `RemoteSizeHandoff.clearScreen` for a `printf` format.
    static let clearScreenEscaped = "\\033[H\\033[2J\\033[3J"

    /// Shell for a repaint's replay, `$1` the zmx path and `$2` the session:
    /// `zmx history --vt` into a variable, with an `x` after it so `$(…)`
    /// keeps its trailing newlines (strip it with `${replay%x}`), and
    /// history's own exit status. The replay is fetched BEFORE the screen
    /// is cleared, so the pane keeps its old view while zmx answers instead
    /// of going blank. A history that works also says the session is still
    /// there: zmx exits 1 for one that has gone and never creates one. Only
    /// a failure falls back to `zmx list`, which is slow: a second for each
    /// session that runs another zmx version, 4s on the mini (2026-11-17).
    static let fetchReplay = #"$("$1" history "$2" --vt 2>/dev/null; s=$?; printf x; exit $s)"#

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
    /// ZMX_SESSION is unset first (by `env -u` here, by the script there),
    /// and zmx's detach key is turned off (`noDetachKey`):
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
            return "/usr/bin/env -u ZMX_SESSION \(noDetachKey) \(zmxPath) attach \(session)"
        }
        var command = "/bin/sh \(script) \(zmxPath) \(session)"
        // Fourth plain token; present only for a surface the recovery manifest
        // named, so an ordinary launch renders exactly the command it did before.
        if let snapshotPath { command += " \(snapshotPath)" }
        return command
    }

    /// Parses full `zmx list` output into session name → root pid, for
    /// foreground-process resolution. Unparseable lines are skipped, and
    /// foreign sessions are dropped — same contract as `zettySessions`.
    public static func sessionPIDs(fromList output: String) -> [String: Int32] {
        var pids: [String: Int32] = [:]
        for line in output.split(separator: "\n") {
            var name: String?
            var pid: Int32?
            for token in line.split(whereSeparator: { $0 == "\t" || $0 == " " }) {
                if token.hasPrefix("name=") { name = String(token.dropFirst(5)) }
                if token.hasPrefix("pid=") { pid = Int32(token.dropFirst(4)) }
            }
            // OURS ONLY, exactly like `zettySessions` below. zmx is shared
            // with other tools, so `zmx list` is not a list of Zetty's panes;
            // a foreign session kept here reaches the task manager, where
            // nothing owns it and it renders as an ORPHAN — the one row killed
            // with no confirmation.
            if let name, let pid, name.hasPrefix(namePrefix) { pids[name] = pid }
        }
        return pids
    }

    /// The probe's session → shell pid map: what `zmx list` gave, plus every
    /// wanted session it left out, from that session's daemon in the process
    /// table (a session of another zmx version, which `list` may skip or name
    /// without a pid). A daemon with no child yet adds nothing.
    public static func sessionPIDs(listed: [String: Int32], daemons: [String: ZmxDaemon],
                                   wanted: Set<String>) -> [String: Int32] {
        var pids = listed
        for name in wanted where pids[name] == nil {
            if let shell = daemons[name]?.shellPID { pids[name] = shell }
        }
        return pids
    }

    /// Every one of our sessions full `zmx list` output names, reachable or
    /// not. zmx 1.0's `list --short` leaves out sessions whose daemon runs
    /// another version (measured 2026-11-13), so a caller that must see every
    /// session (the orphan reap, Settings) lists from the full output.
    public static func sessionNames(fromList output: String) -> [String] {
        output.split(separator: "\n").compactMap { line -> String? in
            let tokens = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard let name = tokens.first(where: { $0.hasPrefix("name=") })?.dropFirst(5),
                  name.hasPrefix(namePrefix) else { return nil }
            return String(name)
        }
    }

    /// Our sessions that `zmx list` could not talk to (`err=…`): since zmx 1.0
    /// that is a session whose daemon runs a different zmx version. Its pid
    /// then comes from the process table (`ZmxDaemons`), never from this list.
    public static func unreachableSessions(fromList output: String) -> [String] {
        output.split(separator: "\n").compactMap { line -> String? in
            let tokens = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard tokens.contains(where: { $0.hasPrefix("err=") }),
                  let name = tokens.first(where: { $0.hasPrefix("name=") })?.dropFirst(5),
                  name.hasPrefix(namePrefix) else { return nil }
            return String(name)
        }
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
