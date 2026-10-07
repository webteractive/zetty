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
        probePanes(surfaceIDs, zmxPath: zmxPath)?.foreground
    }

    /// `probeForeground`, plus the panes whose foreground program has a
    /// command of its own still running, from the same `ps` sweep.
    nonisolated static func probePanes(_ surfaceIDs: [UUID], zmxPath: String)
        -> (foreground: [UUID: String], backgroundWork: Set<UUID>)? {
        let pids = ZmxRunner.sessionPIDs(zmxPath: zmxPath)
        guard !pids.isEmpty, let ps = ZmxRunner.psSnapshot() else { return nil }
        var commands: [UUID: String] = [:]
        var working: Set<UUID> = []
        for id in surfaceIDs {
            guard let pid = pids[SessionPersistence.sessionName(for: id)] else { continue }
            commands[id] = ForegroundProcess.command(forSessionPID: pid, psOutput: ps) ?? ""
            if ForegroundProcess.hasDetachedWork(forSessionPID: pid, psOutput: ps) { working.insert(id) }
        }
        return (commands, working)
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
            handoffWakeSurfaces[id] = record.agent
            handoffWakeStarted.remove(id)
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
        guard handoffWakeSurfaces.removeValue(forKey: surfaceID) != nil else { return }
        handoffWakeStarted.remove(surfaceID)
        HandoffStore.remove(surfaceID)
        ZettyLog.lifecycle.log("handoff: \(SessionPersistence.shortID(for: surfaceID)) consumed")
    }

    /// How long after its wake line is typed a handoff is consumed on the
    /// probe's word alone. Hooks are optional, and by then the harness has
    /// long since read its first message.
    static let handoffConsumeDelay: TimeInterval = 60

    /// The backstop for a pane whose harness never reports through a hook.
    /// It takes its own reading: the poll behind `foregroundBySurface` stops
    /// while Zetty is in the background, and a handoff left unconsumed is
    /// typed into the pane again at the next launch.
    func scheduleHandoffConsume(_ surfaceID: UUID) {
        guard handoffWakeSurfaces[surfaceID] != nil, let zmx = ZmxRunner.locate() else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.handoffConsumeDelay) {
            let running = Self.probeForeground([surfaceID], zmxPath: zmx)?[surfaceID]
            guard let running, AgentKind(rawValue: running).map(HandoffFork.supports) == true
            else { return }
            DispatchQueue.main.async { [weak self] in self?.consumeHandoff(surfaceID) }
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

// MARK: - hibernate-after

/// One candidate project's panes on their way through a `hibernate-after`
/// pass: what the main thread knew, and what was read off it since.
struct AutoHibernationCandidate {
    struct Pane {
        let surface: UUID
        var facts: HibernationEligibility.Pane
        /// Set for a pane holding an agent that can leave a handoff.
        var agent: (kind: AgentKind, session: AgentSession, configDirectory: String?)?
        /// Set instead when no hook, mod or cache names the pane's session,
        /// and its harness's store has to be searched for it.
        var lookup: AgentSessionLookup.Target?
        var transcript: Date?
    }

    let project: UUID
    var panes: [Pane]

    /// Reads what only the disk and the screen can say: each agent's
    /// transcript date, and the prompt box of each pane that needs one.
    /// Blocking — off-main only.
    mutating func readAgents(zmxPath: String) {
        let found = AgentSessionLookup.fallbackSessions(for: panes.compactMap(\.lookup), claimed: [])
        for index in panes.indices {
            if let target = panes[index].lookup, let session = found[panes[index].surface] {
                panes[index].agent = (target.agent, session, target.configDirectory)
            }
            guard let agent = panes[index].agent else { continue }
            panes[index].transcript = AgentTranscript.modificationDate(
                agent: agent.kind, session: agent.session, configDirectory: agent.configDirectory)
            guard HibernationEligibility.needsPromptBox(panes[index].facts),
                  let history = ZmxRunner.historyVT(
                      session: SessionPersistence.sessionName(for: panes[index].surface),
                      zmxPath: zmxPath, timeout: ZmxRunner.teardownCallTimeout)
            else { continue }   // unread stays nil, which keeps the project awake
            panes[index].facts.promptBoxEmpty = PromptBox.isEmpty(
                vtScreen: PromptBox.tail(of: history), agent: agent.kind)
        }
    }
}

extension TerminalViewController {

    /// A key reached a pane: its project is in use, and no longer merely
    /// kept awake because somebody woke it. Two assignments per keystroke;
    /// nothing is saved or refreshed by it.
    func noteUserInput() {
        guard let project = keyboardProject else { return }
        project.lastUsedAt = Date()
        project.keptAwake = false
    }

    /// How long a pass may stay out before it is given up on. Its reads are
    /// bounded individually; this covers a `zmx list` or `ps` that hangs.
    private static let autoHibernationPassTimeout: TimeInterval = 300

    /// One `hibernate-after` pass, every minute.
    ///
    /// Three hops, because the truth is in three places. The idle clock and
    /// the hook states are here on main. What is really in each pane's
    /// foreground has to be read fresh off-main — the poll behind
    /// `foregroundBySurface` stops while Zetty is in the background, which is
    /// exactly when projects go idle. And whether an idle agent has a draft in
    /// front of it, and when it last wrote its transcript, is on disk and on
    /// its screen.
    func evaluateAutoHibernation() {
        let after = autoHibernateAfter?() ?? 0
        guard after > 0, workspace.projects.count > 1 else { return }
        let now = Date()
        if let started = autoHibernationPassStartedAt,
           now.timeIntervalSince(started) < Self.autoHibernationPassTimeout { return }

        let onScreen = projectsOnScreen
        var candidates: [ProjectRuntime] = []
        for project in workspace.projects {
            if onScreen.contains(project.id) { project.lastUsedAt = now; continue }
            if project.lastUsedAt == nil { project.lastUsedAt = now }   // first sight: a full window
            // Transcripts can only make a project LESS idle, so one that is
            // not idle on this clock alone needs nothing read.
            if shouldAutoHibernate(project, after: after, transcripts: [], isBusy: false, now: now) {
                candidates.append(project)
            }
        }
        guard !candidates.isEmpty else { return }

        let surfaces = Dictionary(uniqueKeysWithValues: candidates.map { project in
            (project.id, project.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) })
        })
        guard let zmx = ZmxRunner.locate() else {
            // No zmx: no probe, no screen to read, no handoffs. The last
            // reading there is decides, and any agent pane keeps its project
            // awake, exactly as before handoffs existed.
            for project in candidates {
                let panes = eligibilityPanes(surfaces[project.id] ?? [],
                                             foreground: foregroundBySurface, backgroundWork: [])
                finishAutoHibernation(.init(project: project.id, panes: panes), foreground: nil, after: after)
            }
            return
        }

        autoHibernationPassStartedAt = now
        let allSurfaces = surfaces.values.flatMap { $0 }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let probed = Self.probePanes(allSurfaces, zmxPath: zmx)
            DispatchQueue.main.async {
                guard let self else { return }
                // No answer is "unknown", never "idle": try again next minute.
                guard let probed else { self.autoHibernationPassStartedAt = nil; return }
                let foreground = probed.foreground
                var pending: [AutoHibernationCandidate] = []
                for project in candidates {
                    var panes = self.eligibilityPanes(surfaces[project.id] ?? [], foreground: foreground,
                                                      backgroundWork: probed.backgroundWork)
                    // Anything a screen read cannot excuse ends it here.
                    if panes.contains(where: {
                        HibernationEligibility.keepsAwake($0.facts)
                            && !HibernationEligibility.needsPromptBox($0.facts)
                    }) { continue }
                    for index in panes.indices where HibernationEligibility.needsPromptBox(panes[index].facts) {
                        let id = panes[index].surface
                        // Never the store scan here, once a minute on main.
                        if let found = self.knownResumableSession(for: id, using: foreground) {
                            panes[index].agent = (found.kind, found.session,
                                                  self.harnessConfigDirectory(for: id, kind: found.kind))
                        } else {
                            panes[index].lookup = self.resumeLookupTarget(for: id, using: foreground)
                        }
                    }
                    pending.append(.init(project: project.id, panes: panes))
                }
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    var read = pending
                    for index in read.indices { read[index].readAgents(zmxPath: zmx) }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.autoHibernationPassStartedAt = nil
                        for candidate in read {
                            self.finishAutoHibernation(candidate, foreground: foreground, after: after)
                        }
                    }
                }
            }
        }
    }

    /// Each pane with its hook state, and the foreground command from
    /// `foreground`. A pane with no session there has no entry, which reads
    /// as not probed.
    private func eligibilityPanes(_ surfaces: [UUID], foreground: [UUID: String],
                                  backgroundWork: Set<UUID>) -> [AutoHibernationCandidate.Pane] {
        surfaces.map { id in
            .init(surface: id,
                  facts: .init(foreground: foreground[id],
                               agentStatus: agentDetector.state(for: id).status,
                               hasBackgroundWork: backgroundWork.contains(id)))
        }
    }

    private func shouldAutoHibernate(_ project: ProjectRuntime, after: TimeInterval,
                                     transcripts: [Date], isBusy: Bool, now: Date) -> Bool {
        HibernationPolicy.shouldHibernate(
            idleFor: HibernationPolicy.idleFor(now: now, lastUsedAt: project.lastUsedAt,
                                               transcripts: transcripts),
            hibernateAfter: after, isBusy: isBusy, isActive: false,
            isHibernated: project.isHibernated,
            autoDisabled: autoHibernateDisabled?(project) ?? false,
            isHome: project.isHome, isKept: project.keptAwake)
    }

    /// Back on main with everything read. All of it is re-checked: a
    /// minute's worth of world happened meanwhile.
    private func finishAutoHibernation(_ candidate: AutoHibernationCandidate,
                                       foreground: [UUID: String]?, after: TimeInterval) {
        guard let project = workspace.projects.first(where: { $0.id == candidate.project }),
              !projectsOnScreen.contains(project.id) else { return }
        // A pane added since is unexamined, and a hook may have reported
        // since the screens were read.
        let current = project.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }
        guard Set(current) == Set(candidate.panes.map(\.surface)) else { return }
        let busy = candidate.panes.contains { pane in
            var facts = pane.facts
            facts.agentStatus = agentDetector.state(for: pane.surface).status
            return HibernationEligibility.keepsAwake(facts)
        }
        let transcripts = Dictionary(uniqueKeysWithValues: candidate.panes.compactMap { pane in
            pane.transcript.map { (pane.surface, $0) }
        })
        guard shouldAutoHibernate(project, after: after, transcripts: Array(transcripts.values),
                                  isBusy: busy, now: Date()) else { return }
        // What the store scan found, so the capture does not scan again.
        for pane in candidate.panes where pane.lookup != nil {
            if let agent = pane.agent {
                rememberLookedUpSession(agent.session, kind: agent.kind, for: pane.surface)
            }
        }
        ZettyLog.lifecycle.log("hibernate-after: putting \(project.name) away")
        hibernateProject(project, confirmIfBusy: false,
                         handoffs: .automatic(transcripts: transcripts,
                                              foreground: foreground ?? foregroundBySurface))
    }
}
