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
    /// Blocking — call off-main, or with a `timeout` where that cannot be
    /// helped: a hung zmx otherwise holds the caller for good.
    static func sessionPIDs(zmxPath: String, timeout: TimeInterval? = nil) -> [String: Int32] {
        guard let output = run(zmxPath, ["list"], timeout: timeout) else { return [:] }
        return SessionPersistence.sessionPIDs(fromList: output)
    }

    /// One process-table snapshot, feeding BOTH foreground resolution and the
    /// task manager's session load (nil on failure). Blocking — call off-main.
    ///
    /// One sweep, deliberately: a second polling loop is the mistake the git
    /// pill and synchronous chrome refresh already made here.
    static func psSnapshot(timeout: TimeInterval? = nil) -> String? {
        run("/bin/ps", ["-axo", ProcessTable.psFormat], timeout: timeout)
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
            // A closed pane comes through here, and a Codex among them would
            // otherwise leave its commands running under its daemon.
            stopCodexTerminals(in: sessions, zmxPath: zmxPath)
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
            stopCodexTerminals(in: plan.all, zmxPath: zmxPath)
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

    /// Has every Codex among `sessions` stop what it has running, before the
    /// caller ends them. Blocking — off-main only.
    ///
    /// Which sessions hold Codex is read here, at this moment, and both calls
    /// are bounded like the rest of the teardown. The hibernation plan used
    /// to name them from the probe's map, which a closed pane's plan does not
    /// carry and which runs up to three seconds behind.
    ///
    /// `together` stops them all at once rather than one after another, for
    /// the quit path, where nothing else is ending sessions and the wait is
    /// the user's. Each Codex with something running costs a few seconds.
    static func stopCodexTerminals(in sessions: [String], zmxPath: String, together: Bool = false) {
        let timeout = teardownCallTimeout
        guard !sessions.isEmpty else { return }
        let pids = sessionPIDs(zmxPath: zmxPath, timeout: timeout)
        guard !pids.isEmpty, let ps = psSnapshot(timeout: timeout) else { return }
        let codex = HibernationTeardown.codexSessions(among: sessions, pids: pids, psOutput: ps)
        if together {
            DispatchQueue.concurrentPerform(iterations: codex.count) { index in
                stopCodexTerminals(session: codex[index], zmxPath: zmxPath, timeout: timeout)
            }
            return
        }
        for session in codex {
            // One at a time. Closing a pane ends its session by two routes
            // at once (`kill` and `endSessions`), and both typing `/stop`
            // would put `/stop/stop` in the composer. The second in line
            // reads the screen afresh and finds nothing left to do.
            codexStopLock.lock()
            stopCodexTerminals(session: session, zmxPath: zmxPath, timeout: timeout)
            codexStopLock.unlock()
        }
    }

    private static let codexStopLock = NSLock()

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
        // Codex turns on the kitty keyboard protocol, under which Escape
        // arrives as `CSI 27 u` and a bare ESC byte is ignored: the first
        // version sent the bare byte, and a working Codex's command outlived
        // the hibernate. The bare byte is the second try, for a Codex that
        // has the protocol off.
        var escapes = [kittyEscape, "\u{1B}"]
        for _ in 0..<3 {   // at most: interrupt, interrupt the other way, stop
            guard let history = historyVT(session: session, zmxPath: zmxPath, timeout: timeout)
            else { return }
            switch PromptBox.codexStopStep(vtScreen: PromptBox.tail(of: history)) {
            case .nothing:
                return
            case .interrupt:
                guard !escapes.isEmpty,
                      send(session: session, text: escapes.removeFirst(), zmxPath: zmxPath, timeout: timeout)
                else { return }
                Thread.sleep(forTimeInterval: interruptSettle)
            case .stop:
                guard send(session: session, text: "/stop", zmxPath: zmxPath, timeout: timeout)
                else { return }
                Thread.sleep(forTimeInterval: enterDelay)
                send(session: session, text: "\r", zmxPath: zmxPath, timeout: timeout)
                Thread.sleep(forTimeInterval: interruptSettle)
                ZettyLog.lifecycle.log("teardown: asked codex in \(session) to stop its terminals")
                return
            }
        }
    }

    /// Escape as the kitty keyboard protocol encodes it. Claude and Codex
    /// both turn the protocol on, and neither acts on a bare ESC byte then.
    private static let kittyEscape = "\u{1B}[27u"
    /// The gap between a line and its Enter. Arriving together they are read
    /// as a paste, and the Enter is kept as a newline.
    private static let enterDelay: TimeInterval = 0.3
    /// How long a harness is given to act on a key before it is looked at
    /// again.
    private static let interruptSettle: TimeInterval = 1.5

    /// Ctrl+C in the same encoding. It clears a prompt box that holds text,
    /// and a raw 0x03 did nothing to either harness.
    private static let kittyControlC = "\u{1B}[99;5u"

    /// Has the agent in `session` compact its conversation, in its own chat,
    /// and waits for the harness to say it has. Nil when cancelled. Blocking
    /// for up to `HandoffCompaction.timeout` — off-main only.
    ///
    /// A box that holds a draft or a question is left exactly as it is, and
    /// is a failure: the line would join the draft or answer the question,
    /// and neither is ours to throw away. Only then is a turn in progress
    /// stopped (`midTurn` is Claude's hooks saying so; a working Codex shows
    /// on its screen). Claude puts an interrupted prompt back in its box, so
    /// a box that was empty before the interrupt and is not after it holds
    /// only that, and is cleared.
    ///
    /// The Enter goes in a write of its own: both harnesses read text and
    /// Enter arriving together as a paste and keep the Enter as a newline.
    static func compact(session: String, agent: AgentKind, midTurn: Bool, transcript: URL,
                        zmxPath: String, isCancelled: () -> Bool) -> HandoffCompaction.Result? {
        guard let line = HandoffCompaction.line(for: agent) else { return .failed("its harness cannot compact") }
        let timeout = teardownCallTimeout
        func screen() -> String? {
            historyVT(session: session, zmxPath: zmxPath, timeout: timeout).map { PromptBox.tail(of: $0) }
        }
        func press(_ key: String) -> PromptBox.Readiness? {
            guard send(session: session, text: key, zmxPath: zmxPath, timeout: timeout) else { return nil }
            Thread.sleep(forTimeInterval: interruptSettle)
            return screen().map { PromptBox.readiness(vtScreen: $0, agent: agent) }
        }
        let unreadable = HandoffCompaction.Result.failed("its screen could not be read")

        guard let first = screen() else { return unreadable }
        guard PromptBox.boxIsEmpty(vtScreen: first, agent: agent) else {
            return .failed("its prompt box holds a draft or a question")
        }
        var state = PromptBox.readiness(vtScreen: first, agent: agent)
        if midTurn || state == .working {
            // The bare byte is the second try, for a harness with the
            // keyboard protocol off.
            for escape in [kittyEscape, "\u{1B}"] {
                guard let after = press(escape) else { return unreadable }
                state = after
                if state != .working { break }
            }
            if state == .blocked {
                guard let cleared = press(kittyControlC) else { return unreadable }
                state = cleared
            }
            guard state == .ready else { return .failed("its turn could not be stopped") }
        }
        guard state == .ready else { return .failed("its prompt box holds a draft or a question") }
        if isCancelled() { return nil }

        let sizeBefore = fileSize(transcript)
        guard send(session: session, text: line, zmxPath: zmxPath, timeout: timeout) else {
            return .failed("the request could not be typed")
        }
        Thread.sleep(forTimeInterval: enterDelay)
        guard send(session: session, text: "\r", zmxPath: zmxPath, timeout: timeout) else {
            return .failed("the request could not be submitted")
        }
        ZettyLog.lifecycle.log("handoff: asked \(session) to compact")

        // The transcript is the answer; the screen only tells a compaction
        // still running from a harness that has stopped without doing one.
        let deadline = Date().addingTimeInterval(HandoffCompaction.timeout)
        var seconds = 0
        var restingReads = 0
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            if isCancelled() { return nil }
            if HandoffCompaction.hasCompacted(agent: agent, appended: read(transcript, from: sizeBefore)) {
                return .compacted
            }
            seconds += 1
            guard seconds.isMultiple(of: compactionScreenInterval), let now = screen() else { continue }
            let resting = !PromptBox.isCompacting(vtScreen: now)
                && PromptBox.readiness(vtScreen: now, agent: agent) == .ready
            restingReads = resting ? restingReads + 1 : 0
            // It answered that there is nothing to compact: already a handoff.
            if resting, PromptBox.saysNothingToCompact(vtScreen: now) { return .compacted }
            if restingReads >= compactionRestingReads { return .failed("it did not compact") }
        }
        return .failed("compacting took over \(Int(HandoffCompaction.timeout / 60)) minutes")
    }

    /// How often the screen is read while a compaction is awaited, in
    /// seconds, and how many readings in a row of a harness at rest, with no
    /// compaction in its transcript, are taken to mean there will be none.
    private static let compactionScreenInterval = 5
    private static let compactionRestingReads = 3

    private static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// What a file gained past `offset`, as text.
    private static func read(_ url: URL, from offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Kills the given sessions and waits for zmx to finish — for the quit
    /// path, where an async kill could race app termination.
    static func killAndWait(sessions: [String], zmxPath: String) {
        guard !sessions.isEmpty else { return }
        // A full shutdown ends every session, and a Codex among them would
        // leave its commands running under its daemon with no pane left to
        // stop them from. All at once: the quit is waiting on this.
        stopCodexTerminals(in: sessions, zmxPath: zmxPath, together: true)
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
