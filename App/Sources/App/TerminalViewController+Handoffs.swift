import AppKit
import ZettyCore

/// Hibernation handoffs: what is captured before a project's teardown, what
/// is queued when it wakes, and what the chrome is told meanwhile. The rules
/// are in `.hydra/rules/hibernation-handoffs.md`.
extension TerminalViewController {

    /// Why a hibernation is happening, which decides who gets a handoff.
    enum HandoffRequest {
        /// `--no-handoff`.
        case none
        /// Somebody asked: every agent pane gets one.
        case manual
        /// `hibernate-after`: an agent quiet for over a week gets none. The
        /// evaluation hands over what it just read — each pane's transcript
        /// date and foreground command — so nothing is read twice.
        case automatic(transcripts: [UUID: Date], foreground: [UUID: String])
    }

    /// The foreground command of each pane, read now: "" is an idle shell,
    /// and a pane with no session is left out. nil when zmx or `ps` gave no
    /// answer. Blocking (one `zmx list`, one `ps`).
    ///
    /// The poll behind `foregroundBySurface` stops while Zetty is in the
    /// background, which is when projects go idle and when a script calls
    /// `zetty hibernate`. A pane was still reported as running Codex long
    /// after Codex had quit.
    nonisolated static func probeForeground(_ surfaceIDs: [UUID], zmxPath: String) -> [UUID: String]? {
        let pids = ZmxRunner.sessionPIDs(zmxPath: zmxPath)
        guard !pids.isEmpty, let ps = ZmxRunner.psSnapshot() else { return nil }
        var commands: [UUID: String] = [:]
        for id in surfaceIDs {
            guard let pid = pids[SessionPersistence.sessionName(for: id)] else { continue }
            commands[id] = ForegroundProcess.command(forSessionPID: pid, psOutput: ps) ?? ""
        }
        return commands
    }

    /// The records for a project about to be hibernated, written to disk.
    /// Called BEFORE the teardown: the probe, the hook state and the login
    /// are all gone after it.
    func captureHandoffRecords(for project: ProjectRuntime, surfaceIDs: [UUID],
                               request: HandoffRequest) -> [HandoffRecord] {
        if case .none = request { return [] }
        guard handoffsEnabled?(project) == true else { return [] }

        var manual = true
        var transcripts: [UUID: Date] = [:]
        var foreground: [UUID: String]?
        if case .automatic(let dates, let read) = request {
            manual = false
            transcripts = dates
            foreground = read
        } else if !NSApp.isActive, let zmx = ZmxRunner.locate() {
            foreground = Self.probeForeground(surfaceIDs, zmxPath: zmx)
        }

        let now = Date()
        var records: [HandoffRecord] = []
        for id in surfaceIDs {
            guard let (kind, session) = resumableSession(for: id, using: foreground),
                  HandoffFork.supports(kind) else { continue }
            let quietFor = transcripts[id].map { now.timeIntervalSince($0) }
            guard HandoffPolicy.writesHandoff(manual: manual, agentQuietFor: quietFor) else {
                ZettyLog.lifecycle.log(
                    "handoff: \(SessionPersistence.shortID(for: id)) skipped, quiet for over a week")
                continue
            }
            let record = HandoffRecord(
                surface: id, agent: kind, sessionID: session.id, cwd: session.cwd,
                accountID: harnessAccount(for: id, kind: kind).accountID, requestedAt: now)
            HandoffStore.begin(record)
            records.append(record)
        }
        if !records.isEmpty {
            ZettyLog.lifecycle.log("handoff: \(records.count) pane(s) of \(project.name) owe one")
        }
        return records
    }
}
