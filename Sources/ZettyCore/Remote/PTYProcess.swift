import Darwin
import Foundation

/// A child process on a pty of its own: what the serving Mac runs for one
/// remote pane (the scrollback-restore script, or `zmx attach`).
///
/// Spawned with `posix_spawn`, never `fork`, so nothing of the Swift runtime
/// runs in a half-copied child. The child gets a new session whose controlling
/// terminal is the pty, so a resize reaches it as SIGWINCH and closing the
/// master hangs it up.
public final class PTYProcess: @unchecked Sendable {
    public struct SpawnError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Non-blocking. Owned by this object: `terminate()` closes it, so cancel
    /// any dispatch source reading it first.
    public let masterFD: Int32
    public let pid: pid_t

    private let lock = NSLock()
    private var finished = false

    private init(masterFD: Int32, pid: pid_t) {
        self.masterFD = masterFD
        self.pid = pid
    }

    /// `arguments` excludes argv[0]. The child sees `environment` and nothing
    /// else of this process's.
    public static func spawn(executable: String, arguments: [String], environment: [String: String],
                             rows: UInt16, cols: UInt16) throws -> PTYProcess {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw SpawnError(description: "openpty: \(String(cString: strerror(errno)))")
        }
        defer { close(slave) }
        guard let name = ttyname(slave) else {
            close(master)
            throw SpawnError(description: "ttyname: \(String(cString: strerror(errno)))")
        }
        let slavePath = String(cString: name)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // SETSIGMASK matters: GCD worker threads block signals, and a child
        // spawned from one inherits that mask, so it would never see SIGWINCH
        // or SIGHUP. Both sets are ignored without their flags.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                  | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // Default dispositions and an empty mask, whatever this process has.
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opening the slave by path in the new session makes it the
        // controlling terminal; fd 0 first, then 1 and 2 as copies.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        guard status == 0 else {
            close(master)
            throw SpawnError(description: "\(executable): \(String(cString: strerror(status)))")
        }
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return PTYProcess(masterFD: master, pid: pid)
    }

    public func resize(rows: UInt16, cols: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    /// Hangs up the child's process group, kills it if it is still there after
    /// 1s, and reaps it. Blocks for up to that second, so call it off main.
    /// Idempotent.
    public func terminate() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()

        close(masterFD)
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r == -1 && errno == ECHILD) { return }
            usleep(20_000)
        }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    deinit { terminate() }
}
