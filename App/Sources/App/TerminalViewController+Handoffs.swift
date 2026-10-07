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

// MARK: - Waking

extension TerminalViewController {

    /// Queues each pane's way back, before a woken project's panes spawn.
    /// Delivered lazily like every startup command, so a tab nobody opens
    /// spends no turn.
    func queueHandoffWakes(for project: ProjectRuntime) {
        for surface in project.tabList.trees.flatMap({ $0.layout.surfaces }) {
            guard let record = HandoffStore.record(for: surface.id) else { continue }
            let pending = handoffRunner.isPending(surface.id)
            // A pane woken before its handoff is ready gets its old
            // conversation back, and the fork's output must never land after.
            if pending { handoffRunner.cancel(surface.id) }
            queueHandoffWake(record, surface: surface, forkPending: pending)
        }
    }

    private func queueHandoffWake(_ record: HandoffRecord, surface: Surface, forkPending: Bool) {
        let id = surface.id
        let login = AgentAccountResolver.resumeLogin(
            agentID: record.agent.rawValue, runningAccountID: record.accountID,
            spawnedAccountID: surface.accountID, accounts: accountsProvider?() ?? [],
            home: NSHomeDirectory())
        let plan = HandoffWake.plan(record: record, handoffReady: HandoffStore.isReady(id),
                                    forkPending: forkPending,
                                    handoffPath: HandoffStore.handoffPath(for: id), login: login)
        ZettyLog.lifecycle.log("handoff: \(SessionPersistence.shortID(for: id)) wakes \(plan.logName)")
        switch plan {
        case .fresh(let command):
            // Guarded like a recovery resume: never typed into a live agent.
            queueStartupCommands([id: command], asAgentResume: true)
            handoffWakeSurfaces.insert(id)
        case .resume(let command):
            queueStartupCommands([id: command], asAgentResume: true)
            HandoffStore.remove(id)
        case .plainShell:
            HandoffStore.remove(id)
            return
        }
        // The chip must name the login the agent comes back under, and the
        // probe must not clear it while the pane sits at a bare shell.
        if login != .inherited, let account = record.accountID {
            holdRunningAccountForResume(surfaceID: id, accountID: account)
        }
    }

    /// What `zetty status` says about a hibernated pane: `writing` while its
    /// handoff is owed, `ready` once waking will start a fresh agent from it.
    func handoffState(for surfaceID: UUID) -> String? {
        if handoffRunner.isPending(surfaceID) { return "writing" }
        return HandoffStore.record(for: surfaceID) != nil && HandoffStore.isReady(surfaceID)
            ? "ready" : nil
    }

    /// The woken agent has read its first message: the handoff is spent.
    func consumeHandoff(_ surfaceID: UUID) {
        guard handoffWakeSurfaces.remove(surfaceID) != nil else { return }
        HandoffStore.remove(surfaceID)
        ZettyLog.lifecycle.log("handoff: \(SessionPersistence.shortID(for: surfaceID)) consumed")
    }

    /// How long after its wake line is typed a handoff is consumed on the
    /// probe's word alone. Hooks are optional, and by then the harness has
    /// long since read its first message.
    static let handoffConsumeDelay: TimeInterval = 60

    /// The backstop for a pane whose harness never reports through a hook.
    func scheduleHandoffConsume(_ surfaceID: UUID) {
        guard handoffWakeSurfaces.contains(surfaceID) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffConsumeDelay) { [weak self] in
            guard let self, let running = self.foregroundBySurface[surfaceID],
                  AgentKind(rawValue: running).map(HandoffFork.supports) == true else { return }
            self.consumeHandoff(surfaceID)
        }
    }

    /// A quit ends running forks and loses queued wake lines; the files say
    /// what is still owed. Called once at launch, after accounts and settings
    /// are loaded.
    func restoreHandoffState() {
        var owed: [HandoffRecord] = []
        for record in HandoffStore.allRecords() {
            // A pane that is gone is the sweep's.
            guard let project = workspace.project(containing: record.surface),
                  let surface = workspace.surface(with: record.surface) else { continue }
            let ready = HandoffStore.isReady(record.surface)
            switch (project.isHibernated, ready) {
            case (true, true):
                break                                   // waits for the wake
            case (true, false):
                if handoffsEnabled?(project) == true { owed.append(record) }
                else { HandoffStore.remove(record.surface) }
            case (false, true):
                // Awake with a handoff never consumed: its wake line was lost
                // with the quit. A restart-recovery resume for the same pane
                // describes something later and wins; guarded delivery skips a
                // pane whose agent is in fact already running.
                guard !hasPendingStartupCommand(for: record.surface) else {
                    HandoffStore.remove(record.surface)
                    continue
                }
                queueHandoffWake(record, surface: surface, forkPending: false)
            case (false, false):
                HandoffStore.remove(record.surface)
            }
        }
        handoffRunner.enqueue(owed.sorted { $0.requestedAt < $1.requestedAt })
    }
}
