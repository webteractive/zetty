import Foundation

/// One Zetty session's zmx daemon, from a `ps` snapshot.
public struct ZmxDaemon: Equatable, Sendable {
    public let pid: Int32
    /// argv[0] as `ps` shows it. The App layer resolves the real executable
    /// with `proc_pidpath`; this is the fallback and what tests can see.
    public let executable: String
    /// The session's shell (the daemon's child), when the snapshot has it.
    public let shellPID: Int32?

    public init(pid: Int32, executable: String, shellPID: Int32?) {
        self.pid = pid
        self.executable = executable
        self.shellPID = shellPID
    }
}

/// Maps Zetty's zmx sessions to the daemons serving them.
///
/// Since zmx 1.0 a daemon only talks to clients of its own version, and a
/// 1.0.1 `kill` aimed at a 0.6.0 daemon hangs for good (measured 2026-11-13),
/// so every per-session call has to go through the binary its daemon runs.
/// The process table is the one source that names that binary for every
/// version: `zmx list` run by another version reports the session only as
/// unreachable.
public enum ZmxDaemons {
    /// Daemons keyed by session name, Zetty's sessions only. A daemon is the
    /// row whose parent is launchd and whose argv is a `zmx` executable,
    /// `attach`, then (after any options) the session name: zmx forks it from
    /// the first attach and it keeps that command line. A client always has a
    /// real parent (`ZmxAttachProcesses` relies on the same rule).
    public static func daemons(psOutput: String) -> [String: ZmxDaemon] {
        let table = ProcessTable(psOutput: psOutput)
        var shells: [Int32: Int32] = [:]   // daemon pid → its child
        for sample in table.samples.values {
            if let existing = shells[sample.ppid], existing < sample.pid { continue }
            shells[sample.ppid] = sample.pid
        }
        var found: [String: ZmxDaemon] = [:]
        for sample in table.samples.values where sample.ppid == 1 {
            let argv = sample.command.split(separator: " ").map(String.init)
            guard argv.count >= 3,
                  (argv[0] as NSString).lastPathComponent == "zmx",
                  argv[1] == "attach",
                  let name = sessionArgument(Array(argv.dropFirst(2))),
                  name.hasPrefix(SessionPersistence.namePrefix) else { continue }
            let daemon = ZmxDaemon(pid: sample.pid, executable: argv[0], shellPID: shells[sample.pid])
            // Two launchd-parented rows for one name happen (a stale client of
            // an earlier Zetty, seen on the laptop): the daemon is the one
            // with the session's shell under it.
            if let existing = found[name], existing.shellPID != nil, daemon.shellPID == nil { continue }
            found[name] = daemon
        }
        return found
    }

    /// The session name in `attach`'s arguments: the first that isn't an
    /// option or an option's value.
    private static func sessionArgument(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--labels" { index += 2; continue }
            if argument.hasPrefix("-") { index += 1; continue }
            return argument
        }
        return nil
    }
}

/// `zmx version` output.
public enum ZmxVersion {
    /// The version on the `zmx` line, e.g. `1.0.1`. It names a directory
    /// (`~/.zetty/zmx/<version>/`), so only digits, letters, dots and dashes
    /// get through.
    public static func parse(versionOutput: String) -> String? {
        for line in versionOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 2, fields[0] == "zmx" else { continue }
            let version = String(fields[1])
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
            guard !version.isEmpty, !version.hasPrefix("."), !version.contains(".."),
                  version.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            return version
        }
        return nil
    }

    /// The version folder of Zetty's zmx store (`<store>/<version>/…`) that
    /// `path` sits directly in, or nil. A daemon started from a store copy
    /// that a later launch replaced runs a deleted file (each build signs
    /// its helper anew, so the bytes differ); its folder still names the
    /// version it speaks, and copies of one version are interchangeable.
    public static func storeVersion(ofExecutable path: String, store: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let storeParts = store.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), parts.count == storeParts.count + 2,
              Array(parts.prefix(storeParts.count)) == storeParts else { return nil }
        let version = String(parts[storeParts.count])
        // The same rule `parse` applies, since the result names a folder.
        guard parse(versionOutput: "zmx \(version)") == version else { return nil }
        return version
    }

    /// The `socket_dir` line: the folder holding this zmx's session sockets
    /// (`ZMX_DIR`, or zmx's default under `TMPDIR`). The process table is
    /// machine-wide, so this is what tells this app's sessions from another
    /// Zetty's (the isolated test app) or anyone else's.
    public static func socketDirectory(versionOutput: String) -> String? {
        for line in versionOutput.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0] == "socket_dir" else { continue }
            let path = fields[1].trimmingCharacters(in: .whitespaces)
            return path.hasPrefix("/") ? path : nil
        }
        return nil
    }
}

/// `scripts/zmx.pin`: the zmx release every build bundles.
public struct ZmxPin: Equatable, Sendable {
    public let version: String
    /// sha256 of each architecture's release tarball, keyed `aarch64`/`x86_64`.
    public let sha256: [String: String]

    public init(version: String, sha256: [String: String]) {
        self.version = version
        self.sha256 = sha256
    }

    public static let architectures = ["aarch64", "x86_64"]

    /// nil unless it names a version and a checksum for both architectures.
    public static func parse(_ text: String) -> ZmxPin? {
        var version: String?
        var sums: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "version" { version = value }
            if key.hasPrefix("sha256-") { sums[String(key.dropFirst(7))] = value }
        }
        guard let version, !version.isEmpty,
              architectures.allSatisfy({ sums[$0]?.isEmpty == false }) else { return nil }
        return ZmxPin(version: version, sha256: sums)
    }
}

/// What a zmx command line is aimed at.
public enum ZmxCommand {
    /// Subcommands whose arguments name sessions. Everything else (`list`,
    /// `version`, `help`, `completions`) runs with the bundled binary.
    private static let sessionSubcommands: Set<String> = [
        "attach", "a", "run", "r", "send", "history", "kill", "k", "get", "set", "clear",
        "print-env", "write", "tail", "wait",
    ]

    /// The sessions a command operates on, in order. Only names Zetty owns
    /// count: a foreign session never changes which binary runs.
    public static func targetSessions(_ arguments: [String]) -> [String] {
        guard let subcommand = arguments.first, sessionSubcommands.contains(subcommand) else { return [] }
        return arguments.dropFirst().filter { $0.hasPrefix(SessionPersistence.namePrefix) }
    }

    /// Whether a session-naming command uses zmx's trailing-`*` prefix match
    /// (`kill 'zetty-*'`). zmx expands it itself, across every session in the
    /// folder, so it would reach sessions of other zmx versions.
    public static func usesPattern(_ arguments: [String]) -> Bool {
        guard let subcommand = arguments.first, sessionSubcommands.contains(subcommand) else { return false }
        return arguments.dropFirst().contains { $0.hasSuffix("*") }
    }

    /// One zmx process to run.
    public struct Run: Equatable, Sendable {
        public let binary: String
        public let arguments: [String]
        public init(binary: String, arguments: [String]) {
            self.binary = binary
            self.arguments = arguments
        }
    }

    /// How to run `arguments` so each named session gets the binary its daemon
    /// runs (`binaryFor`; nil = unreachable). nil when the command names no
    /// session (run it as asked). Otherwise one run per binary, each naming
    /// only that binary's sessions, in first-seen order; unreachable sessions
    /// are dropped from every run, and a command naming only unreachable
    /// sessions runs nothing (empty).
    public static func route(_ arguments: [String], binaryFor: (String) -> String?) -> [Run]? {
        let sessions = targetSessions(arguments)
        guard !sessions.isEmpty else { return nil }
        var groups: [(binary: String, sessions: [String])] = []
        for session in sessions {
            guard let binary = binaryFor(session) else { continue }
            if let index = groups.firstIndex(where: { $0.binary == binary }) {
                groups[index].sessions.append(session)
            } else {
                groups.append((binary, [session]))
            }
        }
        let named = Set(sessions)
        return groups.map { group in
            // The group's sessions where the first named session stood, the
            // rest of the arguments (subcommand, flags, text) as they were.
            var rebuilt: [String] = []
            var placed = false
            for argument in arguments {
                if named.contains(argument) {
                    if !placed { rebuilt += group.sessions; placed = true }
                } else {
                    rebuilt.append(argument)
                }
            }
            return Run(binary: group.binary, arguments: rebuilt)
        }
    }
}
