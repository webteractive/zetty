import Foundation

/// Resolves what a preserved pane is actually running, from a `ps` snapshot.
///
/// libghostty exposes no PTY/pid, but a zmx-backed pane does: `zmx list` gives
/// the session's root shell pid. That pid's TTY hosts one foreground process
/// group — its leader is "the CLI running in the pane" (codex, claude, vim …).
/// A shell as the foreground leader means the pane is idle at a prompt.
public enum ForegroundProcess {

    struct Row {
        let pid: Int32
        let ppid: Int32
        let pgid: Int32
        let stat: String
        let tty: String
        let comm: String
    }

    /// The foreground command on the TTY of `sessionPID`, from the output of
    /// `ps -axo` with `ProcessTable.psFormat`. Returns the process-group
    /// leader's tool name, or nil when the pane is idle (shell in the
    /// foreground), the pid is unknown, or it has no TTY.
    public static func command(forSessionPID sessionPID: Int32, psOutput: String) -> String? {
        foregroundLeader(forSessionPID: sessionPID, in: parse(psOutput))?.name
    }

    /// Whether the program in the pane's foreground has work of its own still
    /// running: a descendant with no terminal.
    ///
    /// An agent runs each command it starts as a session of its own, off the
    /// pane's terminal, while its helpers (MCP servers, a language server)
    /// stay on it. So a dev server an agent started and left running shows
    /// here after its turn has ended, when its hooks say idle and its prompt
    /// box is empty. A different process GROUP alone is not the sign: Codex
    /// keeps its helpers in groups of their own, on the terminal. Read off
    /// claude 2.1.292. False for an idle shell, whose own jobs are not this.
    public static func hasDetachedWork(forSessionPID sessionPID: Int32, psOutput: String) -> Bool {
        let rows = parse(psOutput)
        guard let leader = foregroundLeader(forSessionPID: sessionPID, in: rows) else { return false }
        var children: [Int32: [Row]] = [:]
        for row in rows { children[row.ppid, default: []].append(row) }
        var pending = children[leader.row.pid] ?? []
        var seen: Set<Int32> = [leader.row.pid]
        while let row = pending.popLast() {
            guard seen.insert(row.pid).inserted else { continue }
            if row.tty == "??" { return true }
            pending.append(contentsOf: children[row.pid] ?? [])
        }
        return false
    }

    /// The process-group leader in the foreground of the session's terminal,
    /// with its tool name; nil when that is a shell at its prompt.
    private static func foregroundLeader(forSessionPID sessionPID: Int32,
                                         in rows: [Row]) -> (row: Row, name: String)? {
        guard let session = rows.first(where: { $0.pid == sessionPID }),
              !session.tty.isEmpty, session.tty != "??" else { return nil }

        let foreground = rows.filter { $0.tty == session.tty && $0.stat.contains("+") }
        guard let leader = foreground.first(where: { $0.pid == $0.pgid }) ?? foreground.first,
              let name = toolName(fromCommandLine: leader.comm),
              !TabTitle.isShellName(name) else { return nil }
        return (leader, name)
    }

    /// Interpreters whose argv[0] hides the real tool (a python CLI's process
    /// is `python3 /path/to/tool`); the first non-flag argument names it.
    private static let interpreters: Set<String> = ["python", "node", "nodejs", "ruby", "perl", "php"]

    /// Resolves a full command line to the tool's display name: argv[0]
    /// basename, or — for interpreters — the first non-flag argument's
    /// basename (a bare interpreter REPL keeps its own name).
    static func toolName(fromCommandLine line: String) -> String? {
        let argv = line.split(separator: " ").map(String.init)
        guard let binary = argv.first.map(basename(of:)) else { return nil }

        // "python3.11" → "python" for the interpreter check only.
        let stripped = binary.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))
        guard interpreters.contains(stripped) else { return binary }
        guard let script = argv.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
            return binary   // interactive REPL — the interpreter is the tool
        }
        return basename(of: script)
    }

    // MARK: - Parsing

    private static func parse(_ output: String) -> [Row] {
        // Shares `ProcessTable.psFormat` with the task manager's sampler so one
        // `ps` sweep feeds both; only four of the eight fields matter here.
        // Command stays last and is taken as the remainder (full argv).
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard fields.count == 8,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  let pgid = Int32(fields[2]) else { return nil }
            return Row(
                pid: pid,
                ppid: ppid,
                pgid: pgid,
                stat: String(fields[3]),
                tty: String(fields[4]),
                comm: fields[7].trimmingCharacters(in: .whitespaces)
            )
        }
    }

    private static func basename(of command: String) -> String {
        command.contains("/") ? URL(fileURLWithPath: command).lastPathComponent : command
    }
}
