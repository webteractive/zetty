import Darwin
import Foundation

/// One `zetty.exec` command.
public struct LuaCommand: Equatable, Sendable {
    public enum Program: Equatable, Sendable {
        /// Run with `/bin/sh -c`.
        case shell(String)
        /// Run directly, no shell: `argv[0]` is looked up on the command's `PATH`.
        case argv([String])
    }

    public var program: Program
    public var cwd: String
    public var timeout: TimeInterval
    public var environment: [String: String]

    public init(program: Program, cwd: String, timeout: TimeInterval, environment: [String: String]) {
        self.program = program
        self.cwd = cwd
        self.timeout = timeout
        self.environment = environment
    }
}

public struct LuaCommandResult: Equatable, Sendable {
    /// The exit status, or 128 + the signal that ended it.
    public var code: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(code: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.code = code
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs `zetty.exec` commands off the main thread. Injected so tests can
/// finish commands on demand.
public protocol LuaCommandRunner: AnyObject {
    /// Starts `command` and returns at once. `completion` runs once it ends,
    /// unless the returned handle was cancelled first.
    func run(_ command: LuaCommand, completion: @escaping (LuaCommandResult) -> Void) -> LuaCancellable
}

/// Real processes, at most `maxConcurrent` at once (the rest wait in order).
///
/// Each command is spawned into its own process group, so a timeout or
/// cancel signals everything it started. A command is finished when the
/// spawned process exits: output still arriving is read for a short grace
/// period and then dropped, so a background child that keeps the pipe open
/// (`sleep 60 &`) cannot hold the callback back.
public final class ProcessCommandRunner: LuaCommandRunner, @unchecked Sendable {
    private let maxConcurrent: Int
    private let outputCap: Int
    private let killGrace: TimeInterval
    private let deliverOn: DispatchQueue
    /// How often a running command's worker checks for exit and its timeout.
    private let pollInterval: TimeInterval
    /// Guards `running` and `pending`.
    private let bookkeeping = DispatchQueue(label: "zetty.lua.exec")
    private var running = 0
    private var pending: [Job] = []

    /// How long output is still read after the process exits.
    static let drainGrace: TimeInterval = 0.25

    public init(maxConcurrent: Int = 8, outputCap: Int = 1_048_576, killGrace: TimeInterval = 2,
                pollInterval: TimeInterval = 0.02, deliverOn: DispatchQueue = .main) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.outputCap = outputCap
        self.killGrace = killGrace
        self.pollInterval = pollInterval
        self.deliverOn = deliverOn
    }

    public func run(_ command: LuaCommand, completion: @escaping (LuaCommandResult) -> Void) -> LuaCancellable {
        let job = Job(command: command, completion: completion)
        bookkeeping.async {
            self.pending.append(job)
            self.startNext()
        }
        return job
    }

    /// On `bookkeeping`.
    private func startNext() {
        while running < maxConcurrent, !pending.isEmpty {
            let job = pending.removeFirst()
            if job.isCancelled { continue }
            running += 1
            DispatchQueue.global(qos: .utility).async {
                let result = self.execute(job)
                if !job.isCancelled {
                    self.deliverOn.async {
                        if !job.isCancelled { job.completion(result) }
                    }
                }
                self.bookkeeping.async {
                    self.running -= 1
                    self.startNext()
                }
            }
        }
    }

    // MARK: - One process

    private func execute(_ job: Job) -> LuaCommandResult {
        let command = job.command
        let arguments: [String]
        switch command.program {
        case .shell(let script):
            arguments = ["/bin/sh", "-c", script]
        case .argv(let argv):
            guard let name = argv.first,
                  let path = Self.resolve(name, path: command.environment["PATH"] ?? "", cwd: command.cwd) else {
                return LuaCommandResult(code: 127, stdout: "",
                                        stderr: "command not found: \(command.program.firstWord)", timedOut: false)
            }
            arguments = [path] + argv.dropFirst()
        }

        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { return Self.failure("pipe: \(String(cString: strerror(errno)))") }
        guard pipe(&err) == 0 else {
            close(out[0]); close(out[1])
            return Self.failure("pipe: \(String(cString: strerror(errno)))")
        }
        // Not inherited by anything else the app spawns meanwhile, which
        // would hold the write ends open and delay EOF.
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, command.cwd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = command.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
        close(out[1])
        close(err[1])
        guard spawned == 0 else {
            close(out[0]); close(err[0])
            return Self.failure("could not start: \(String(cString: strerror(spawned)))")
        }
        job.started(processGroup: pid)
        return collect(job, pid: pid, stdout: out[0], stderr: err[0])
    }

    /// Reads both pipes and waits for `pid`, enforcing the timeout and
    /// noticing a cancel. Closes both descriptors.
    private func collect(_ job: Job, pid: pid_t, stdout: Int32, stderr: Int32) -> LuaCommandResult {
        let streams = [CapturedOutput(fd: stdout, cap: outputCap), CapturedOutput(fd: stderr, cap: outputCap)]
        defer { streams.forEach { close($0.fd) } }
        for stream in streams { _ = fcntl(stream.fd, F_SETFL, fcntl(stream.fd, F_GETFL) | O_NONBLOCK) }

        let deadline = Date().addingTimeInterval(job.command.timeout)
        var status: Int32 = 0
        var exitedAt: Date?
        var terminatedAt: Date?
        var killed = false
        var timedOut = false

        while true {
            var fds = streams.filter { !$0.closed }.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            let waitMS = Int32(pollInterval * 1000)
            if !fds.isEmpty { _ = poll(&fds, nfds_t(fds.count), waitMS) } else { usleep(useconds_t(waitMS) * 1000) }
            for stream in streams where !stream.closed { stream.readAvailable() }

            if exitedAt == nil, waitpid(pid, &status, WNOHANG) == pid { exitedAt = Date() }
            let now = Date()
            if let exitedAt {
                let drained = streams.allSatisfy(\.closed)
                if drained || now.timeIntervalSince(exitedAt) > Self.drainGrace { break }
                continue
            }
            if terminatedAt == nil, job.isCancelled || now > deadline {
                timedOut = !job.isCancelled
                kill(-pid, SIGTERM)
                terminatedAt = now
            } else if let terminatedAt, !killed, now.timeIntervalSince(terminatedAt) > killGrace {
                kill(-pid, SIGKILL)
                killed = true
            }
        }

        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return LuaCommandResult(code: code, stdout: streams[0].text, stderr: streams[1].text, timedOut: timedOut)
    }

    private static func failure(_ message: String) -> LuaCommandResult {
        LuaCommandResult(code: 127, stdout: "", stderr: message, timedOut: false)
    }

    /// `name` itself when it holds a slash, else the first executable match on `path`.
    /// A relative name with a slash (`./build.sh`) is taken from `cwd`, the
    /// directory the command runs in, as a shell would; posix_spawn would
    /// otherwise resolve it against Zetty's own working directory.
    static func resolve(_ name: String, path: String, cwd: String) -> String? {
        if name.contains("/") {
            let full = name.hasPrefix("/") ? name : (cwd as NSString).appendingPathComponent(name)
            return FileManager.default.isExecutableFile(atPath: full) ? full : nil
        }
        return path.split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private extension LuaCommand.Program {
    var firstWord: String {
        switch self {
        case .shell(let script): return script
        case .argv(let argv): return argv.first ?? ""
        }
    }
}

/// A queued or running command; cancelling drops its completion.
private final class Job: LuaCancellable, @unchecked Sendable {
    let command: LuaCommand
    let completion: (LuaCommandResult) -> Void
    private let lock = NSLock()
    private var cancelled = false
    /// The running process's group (its pid), 0 before it starts.
    private var processGroup: pid_t = 0

    init(command: LuaCommand, completion: @escaping (LuaCommandResult) -> Void) {
        self.command = command
        self.completion = completion
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Records the spawned group; a cancel that came first signals it now.
    func started(processGroup group: pid_t) {
        lock.lock()
        processGroup = group
        let cancelledFirst = cancelled
        lock.unlock()
        if cancelledFirst { kill(-group, SIGTERM) }
    }

    /// Drops the completion and signals the process group at once: at quit
    /// the app may exit before the worker's next poll would have. The worker
    /// still escalates to SIGKILL and reaps the child.
    func cancel() {
        lock.lock()
        cancelled = true
        let group = processGroup
        lock.unlock()
        if group > 0 { kill(-group, SIGTERM) }
    }
}

/// One pipe's bytes, keeping the first `cap` and counting what was dropped.
private final class CapturedOutput {
    let fd: Int32
    let cap: Int
    private(set) var closed = false
    private var bytes: [UInt8] = []
    private var dropped = false

    init(fd: Int32, cap: Int) {
        self.fd = fd
        self.cap = cap
    }

    func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let room = max(0, cap - bytes.count)
                bytes.append(contentsOf: buffer.prefix(min(room, count)))
                if count > room { dropped = true }
            } else if count == 0 {
                closed = true
                return
            } else {
                if errno != EAGAIN && errno != EINTR { closed = true }
                return
            }
        }
    }

    var text: String {
        String(decoding: bytes, as: UTF8.self) + (dropped ? "\n[truncated]" : "")
    }
}
