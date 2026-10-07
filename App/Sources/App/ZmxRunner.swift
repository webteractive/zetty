import Foundation
import ZettyGhostty

/// Thin process wrapper around the `zmx` binary (session persistence daemon).
///
/// GUI apps don't inherit the shell's PATH, so zmx is located via the standard
/// install directories. All calls are best-effort: a missing binary or failed
/// invocation degrades gracefully (a leftover session is just an orphan the
/// Settings window can clean up).
enum ZmxRunner {

    /// Pinned release downloaded by the in-app installer (from zmx.sh).
    static let version = "0.6.0"

    /// Manual-install guidance shown when the auto-download fails.
    static let installHint = "Download from https://zmx.sh or: brew install neurosnap/tap/zmx"

    /// Where the in-app installer puts the binary.
    static var managedBinaryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".zetty/bin/zmx")
    }

    /// Resolved zmx binary path, or nil when not installed.
    static func locate() -> String? {
        let candidates = [
            managedBinaryURL.path,                      // Zetty-managed download
            "/opt/homebrew/bin/zmx",                    // Homebrew (Apple Silicon)
            "/usr/local/bin/zmx",                       // Homebrew (Intel) / manual
            "\(NSHomeDirectory())/.local/bin/zmx",      // manual install
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `zmx list --short` → Zetty session names, both prefixes (empty on any
    /// failure).
    static func listZettySessions(zmxPath: String) -> [String] {
        guard let output = run(zmxPath, ["list", "--short"]) else { return [] }
        return SessionPersistence.zettySessions(fromList: output)
    }

    /// `zmx list` → session name to root shell pid (empty on any failure).
    /// Blocking — call off-main.
    static func sessionPIDs(zmxPath: String) -> [String: Int32] {
        guard let output = run(zmxPath, ["list"]) else { return [:] }
        return SessionPersistence.sessionPIDs(fromList: output)
    }

    /// One process-table snapshot, feeding BOTH foreground resolution and the
    /// task manager's session load (nil on failure). Blocking — call off-main.
    ///
    /// One sweep, deliberately: a second polling loop is the mistake the git
    /// pill and synchronous chrome refresh already made here.
    static func psSnapshot() -> String? {
        run("/bin/ps", ["-axo", ProcessTable.psFormat])
    }

    /// `zmx history <session>` — the session's retained scrollback as plain
    /// text (nil when the session doesn't exist). Blocking.
    static func history(session: String, zmxPath: String) -> String? {
        run(zmxPath, ["history", session])
    }

    /// `zmx history <session> --vt` — the session's scrollback WITH attributes,
    /// as raw bytes (nil when the session doesn't exist or zmx fails). Bytes,
    /// not String: escape sequences must round-trip untouched into the pane.
    /// Blocking. `timeout` bounds it for a caller that polls: without one a
    /// hung zmx holds its thread for good.
    static func historyVT(session: String, zmxPath: String, timeout: TimeInterval? = nil) -> Data? {
        runData(zmxPath, ["history", session, "--vt"], timeout: timeout)
    }

    /// Kills the given sessions in the background (fire-and-forget).
    static func kill(sessions: [String], zmxPath: String) {
        guard !sessions.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = run(zmxPath, ["kill"] + sessions)
        }
    }

    /// The bound on each zmx call inside `endSessions`. Generous — they
    /// normally take milliseconds — so it only ever trips on a hung zmx.
    static let teardownCallTimeout: TimeInterval = 5

    /// Ends a hibernating project's sessions gracefully: types `exit` into the
    /// idle shells, waits up to the grace period for them to go, then kills
    /// whatever is still listed. `completion` runs on main once nothing of the
    /// plan is left alive — only then may the caller free the panes' surfaces,
    /// since freeing a live preserved surface can block the main thread.
    static func endSessions(_ plan: HibernationTeardown.Plan, zmxPath: String,
                            completion: @escaping @MainActor () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Every call is bounded: a hung zmx must delay a hibernate, never
            // pin its panes (and any queued wake) for good. A send that times
            // out means zmx is not answering, so the rest are not tried.
            let timeout = teardownCallTimeout
            for session in plan.stopFirst {
                stopCodexTerminals(session: session, zmxPath: zmxPath, timeout: timeout)
            }
            for session in plan.exit {
                let started = Date()
                let sent = send(session: session, text: HibernationTeardown.exitInput,
                                zmxPath: zmxPath, timeout: timeout)
                // Only a TIMEOUT means zmx is hung. An ordinary failure (that
                // shell already gone) must not cost the others their `exit`.
                if !sent, Date().timeIntervalSince(started) >= timeout { break }
            }
            // nil when `zmx list` itself failed — which proves nothing, unlike
            // `listZettySessions`'s empty answer, which would read as "every
            // session is gone" and let the caller free live surfaces.
            func list() -> Set<String>? {
                run(zmxPath, ["list", "--short"], timeout: timeout)
                    .map { Set(SessionPersistence.zettySessions(fromList: $0)) }
            }
            var listed = list()
            let deadline = Date() + HibernationTeardown.gracePeriod
            while !(listed.map { plan.exitsFinished(listed: $0) } ?? false), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
                listed = list()
            }
            let toKill = listed.map { plan.remaining(listed: $0) } ?? plan.all
            if !toKill.isEmpty { _ = run(zmxPath, ["kill"] + toKill, timeout: timeout) }
            // `zmx kill` exiting is not the sessions being gone, and the caller
            // frees their surfaces next: confirm, and force what is left.
            if let after = list(), case let left = plan.remaining(listed: after), !left.isEmpty {
                _ = run(zmxPath, ["kill"] + left + ["--force"], timeout: timeout)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion() } }
        }
    }

    /// Has a Codex pane stop what it has running before its session is ended.
    ///
    /// Codex's commands run under its shared daemon, not under the pane, so
    /// killing the session does not reach them: a `sleep` Codex had started
    /// outlived its project's hibernation. The screen is read first and only
    /// what it calls for is typed (`PromptBox.codexStopStep`): Escape if a
    /// turn is running, then `/stop` if a terminal is. The Enter goes in a
    /// write of its own, because Codex reads text and Enter arriving together
    /// as a paste and keeps the Enter as a newline.
    private static func stopCodexTerminals(session: String, zmxPath: String, timeout: TimeInterval) {
        for _ in 0..<3 {   // at most: interrupt, look again, stop
            guard let history = runData(zmxPath, ["history", session, "--vt"], timeout: timeout)
            else { return }
            switch PromptBox.codexStopStep(vtScreen: PromptBox.tail(of: history)) {
            case .nothing:
                return
            case .interrupt:
                guard send(session: session, text: "\u{1B}", zmxPath: zmxPath, timeout: timeout)
                else { return }
                Thread.sleep(forTimeInterval: 1)
            case .stop:
                guard send(session: session, text: "/stop", zmxPath: zmxPath, timeout: timeout)
                else { return }
                Thread.sleep(forTimeInterval: 0.3)
                send(session: session, text: "\r", zmxPath: zmxPath, timeout: timeout)
                Thread.sleep(forTimeInterval: 1.5)
                ZettyLog.lifecycle.log("teardown: asked codex in \(session) to stop its terminals")
                return
            }
        }
    }

    /// Kills the given sessions and waits for zmx to finish — for the quit
    /// path, where an async kill could race app termination.
    static func killAndWait(sessions: [String], zmxPath: String) {
        guard !sessions.isEmpty else { return }
        _ = run(zmxPath, ["kill"] + sessions)
    }

    /// Downloads the pinned zmx release binary from zmx.sh into
    /// `~/.zetty/bin/zmx` (no Homebrew needed). Runs off-main; completion (on
    /// main) gets the resolved zmx path on success, or nil on failure.
    static func install(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let path = downloadAndInstall()
            DispatchQueue.main.async { completion(path) }
        }
    }

    private static func downloadAndInstall() -> String? {
        #if arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x86_64"
        #endif
        let url = "https://zmx.sh/a/zmx-\(version)-macos-\(arch).tar.gz"

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("zetty-zmx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: workDir) }
        let tarball = workDir.appendingPathComponent("zmx.tar.gz")

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            // curl keeps this simple and avoids quarantine-xattr surprises.
            guard run("/usr/bin/curl", ["-fsSL", url, "-o", tarball.path]) != nil else { return nil }
            guard run("/usr/bin/tar", ["-xzf", tarball.path, "-C", workDir.path]) != nil else { return nil }

            // Find the extracted `zmx` binary (archive layout may nest it).
            guard let binary = findBinary(named: "zmx", under: workDir) else { return nil }

            let dest = managedBinaryURL
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: binary, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            return locate()
        } catch {
            return nil
        }
    }

    private static func findBinary(named name: String, under dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }
        for case let url as URL in enumerator
        where url.lastPathComponent == name
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            return url
        }
        return nil
    }

    /// `zmx send <session> <text>` — raw input into the session's PTY.
    ///
    /// Works whether or not a client is attached, which is what lets a pane be
    /// hidden behind a placeholder while its agent is quit and resumed: nothing
    /// has to be detached, and crucially nothing has to be FREED. Tearing a
    /// live preserved surface down is `ghostty_surface_free`, the call that
    /// disabled `free-background-panes-after` because it can block the main
    /// thread — see that section. Driving the session from outside sidesteps
    /// the whole question.
    ///
    /// Blocking — call off-main.
    @discardableResult
    static func send(session: String, text: String, zmxPath: String,
                     timeout: TimeInterval? = nil) -> Bool {
        run(zmxPath, ["send", session, text], timeout: timeout) != nil
    }

    // MARK: - Private

    /// Runs a binary, returning stdout on exit 0 (nil otherwise). Blocking —
    /// call off-main for anything slow.
    @discardableResult
    private static func run(_ path: String, _ args: [String],
                            timeout: TimeInterval? = nil) -> String? {
        runData(path, args, timeout: timeout).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Raw stdout, so callers that must not lose bytes (VT scrollback) don't
    /// go through a lossy String conversion.
    /// - Parameter timeout: when set, the process is terminated (then killed)
    ///   once it runs that long, and the call answers nil — a failure, never a
    ///   partial result. Only the hibernation teardown sets it: a hung zmx
    ///   there would otherwise hold the project's panes forever.
    private static func runData(_ path: String, _ args: [String],
                                timeout: TimeInterval? = nil) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        // Never run zmx "inside" a session: an inherited ZMX_SESSION (Zetty
        // launched from a zmx-backed terminal) changes attach/kill semantics.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZMX_SESSION")
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Installed BEFORE launch, so an exit can never beat it.
        let exited = DispatchSemaphore(value: 0)
        if timeout != nil { process.terminationHandler = { _ in exited.signal() } }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard let timeout else {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return data
        }
        // Read on a worker and WAIT with the deadline: a read blocks until
        // every holder of the pipe exits, and a child the process spawned can
        // outlive a SIGKILL of the process itself — measured, a TERM-ignoring
        // shell held the caller for its child's full 30 s. On timeout the
        // worker is abandoned (it ends when the pipe finally closes).
        //
        // ONE deadline covers the read AND the exit: a process can close its
        // stdout and keep running, so a bare `waitUntilExit` after the read
        // would be the unbounded wait all over again.
        let deadline = DispatchTime.now() + timeout
        let output = OutputBox()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = stdout.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        guard read.wait(timeout: deadline) == .success,
              exited.wait(timeout: deadline) == .success
        else {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
            }
            return nil
        }
        // Reap so the status below is final — never blocks now, it has exited.
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return output.data
    }
}

/// The timed `runData` read's result, handed from its worker to the caller.
/// The semaphore orders the write before the read.
private final class OutputBox: @unchecked Sendable {
    var data = Data()
}
