import Foundation
import ZettyCore

/// Runs the forks that write handoffs: at most `HandoffQueue.maxRunning` at
/// once, each bounded by `HandoffFork.timeout`, never on the main thread.
///
/// A handoff never blocks anything. Whatever goes wrong — no binary, a failed
/// resume, a timeout, an empty reply — the record is removed and that pane
/// wakes the way it did before handoffs existed.
///
/// Main-thread only, like the watchers: every method and both callbacks.
final class HandoffRunner {
    private var queue = HandoffQueue()
    private var records: [UUID: HandoffRecord] = [:]
    private var processes: [UUID: Process] = [:]

    /// A fork was queued, started or finished: the sidebar and status change.
    var onChange: (() -> Void)?
    /// The login variables for a record's account; empty is the default login.
    var accountEnvironment: ((HandoffRecord) -> [String: String])?

    func isPending(_ surface: UUID) -> Bool { queue.isPending(surface) }
    func anyPending(among surfaces: [UUID]) -> Bool { queue.anyPending(among: surfaces) }

    func enqueue(_ new: [HandoffRecord]) {
        guard !new.isEmpty else { return }
        for record in new { records[record.surface] = record }
        queue.enqueue(new.map(\.surface))
        pump()
        onChange?()
    }

    /// Stops a pane's fork and forgets it. What happens to the record on disk
    /// is the caller's decision.
    func cancel(_ surface: UUID) {
        let state = queue.cancel(surface)
        records.removeValue(forKey: surface)
        if state == .wasRunning { terminate(processes.removeValue(forKey: surface)) }
        guard state != .notPending else { return }
        pump()
        onChange?()
    }

    /// Cancels every fork whose pane is no longer in the workspace.
    func cancel(notIn owned: Set<UUID>) {
        for surface in records.keys where !owned.contains(surface) { cancel(surface) }
    }

    /// Quit: nothing may outlive the app. The records stay on disk, and the
    /// next launch queues them again.
    func stopForQuit() {
        for process in processes.values { terminate(process) }
        processes.removeAll()
        queue = HandoffQueue()
        records.removeAll()
    }

    private func pump() {
        for surface in queue.startNext() {
            guard let record = records[surface] else { queue.finish(surface); continue }
            launch(record)
        }
    }

    private func launch(_ record: HandoffRecord) {
        let surface = record.surface
        guard let agent = SpawnableAgent.byID(record.agent.rawValue),
              let binary = AgentAuthRunner.locate(agent),
              let arguments = HandoffFork.arguments(agent: record.agent, sessionID: record.sessionID,
                                                    request: HandoffPrompt.request)
        else {
            finish(surface, handoff: nil, why: "no harness binary or no fork grammar")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: record.cwd, isDirectory: true)
        process.environment = HandoffFork.environment(
            base: ProcessInfo.processInfo.environment, account: accountEnvironment?(record) ?? [:])
        // `claude -p` waits 3 seconds for piped input otherwise.
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Installed BEFORE launch, so an exit can never beat it.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            finish(surface, handoff: nil, why: "could not start: \(error.localizedDescription)")
            return
        }
        processes[surface] = process
        ZettyLog.lifecycle.log("handoff: \(SessionPersistence.shortID(for: surface)) fork started")

        DispatchQueue.global(qos: .utility).async {
            // The read is on its own worker and BOTH waits share one deadline:
            // a read blocks until every holder of the pipe exits, and a
            // process can close stdout and keep running — the two ways
            // `ZmxRunner.runData` learned an unbounded wait hides.
            let output = ForkOutput()
            let read = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                output.data = stdout.fileHandleForReading.readDataToEndOfFile()
                read.signal()
            }
            let deadline = DispatchTime.now() + HandoffFork.timeout
            let finishedInTime = read.wait(timeout: deadline) == .success
                && exited.wait(timeout: deadline) == .success
            var handoff: String?
            var why = "timed out"
            if finishedInTime {
                process.waitUntilExit()   // has exited; this only reaps
                handoff = process.terminationReason == .exit
                    ? HandoffOutput.accepted(exitCode: process.terminationStatus, stdout: output.data)
                    : nil
                why = "exit \(process.terminationStatus), \(output.data.count) bytes"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !finishedInTime { self.terminate(process) }
                self.finish(surface, handoff: handoff, why: why)
            }
        }
    }

    private func finish(_ surface: UUID, handoff: String?, why: String) {
        processes.removeValue(forKey: surface)
        // Cancelled meanwhile (the pane was woken, closed, or the app is
        // quitting): its output must not land.
        guard queue.isRunning(surface) else { return }
        queue.finish(surface)
        records.removeValue(forKey: surface)
        if let handoff {
            HandoffStore.writeHandoff(handoff, for: surface)
            ZettyLog.lifecycle.log("handoff: \(SessionPersistence.shortID(for: surface)) written")
        } else {
            HandoffStore.remove(surface)
            ZettyLog.lifecycle.log("handoff: \(SessionPersistence.shortID(for: surface)) none (\(why))")
        }
        pump()
        onChange?()
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
    }
}

/// A fork's stdout, handed from the reading worker to the waiting one. The
/// semaphore orders the write before the read.
private final class ForkOutput: @unchecked Sendable {
    var data = Data()
}
