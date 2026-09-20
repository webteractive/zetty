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
        let rows = parse(psOutput)
        guard let session = rows.first(where: { $0.pid == sessionPID }),
              !session.tty.isEmpty, session.tty != "??" else { return nil }

        let foreground = rows.filter { $0.tty == session.tty && $0.stat.contains("+") }
        guard let leader = foreground.first(where: { $0.pid == $0.pgid }) ?? foreground.first else {
            return nil
        }
        guard let name = toolName(fromCommandLine: leader.comm) else { return nil }
        return TabTitle.isShellName(name) ? nil : name
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
                  let pid = Int32(fields[0]), let pgid = Int32(fields[2]) else { return nil }
            return Row(
                pid: pid,
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
