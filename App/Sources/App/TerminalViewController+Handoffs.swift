import AppKit
import ZettyCore

/// Hibernation handoffs: what is captured when a project is asked to
/// hibernate, how its agents compact before it is put away, what is queued
/// when it wakes, and what the chrome is told meanwhile. The rules
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
    /// answer. Blocking (one `zmx list`, one `ps`), each bounded: a scripted
    /// hibernate takes this reading on the main thread, where a hung zmx
    /// would freeze the app and every `zetty` command behind it.
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
        let timeout = ZmxRunner.teardownCallTimeout
        let pids = ZmxRunner.sessionPIDs(zmxPath: zmxPath, timeout: timeout)
        guard !pids.isEmpty, let ps = ZmxRunner.psSnapshot(timeout: timeout) else { return nil }
        var commands: [UUID: String] = [:]
        var working: Set<UUID> = []
        for id in surfaceIDs {
            guard let pid = pids[SessionPersistence.sessionName(for: id)] else { continue }
            commands[id] = ForegroundProcess.command(forSessionPID: pid, psOutput: ps) ?? ""
            if ForegroundProcess.hasDetachedWork(forSessionPID: pid, psOutput: ps) { working.insert(id) }
        }
        return (commands, working)
    }

    /// What is in each pane's foreground, for a hibernation about to happen:
    /// the reading `hibernate-after` just took, or a fresh one when Zetty is
    /// in the background and the probe's own is stale. nil is "use the
    /// probe's". Both the handoff capture and the teardown plan read it, so
    /// a scripted hibernate neither misses an agent nor types `exit` into one.
    func foregroundForHibernation(_ surfaceIDs: [UUID], request: HandoffRequest) -> [UUID: String]? {
        if case .automatic(_, let read) = request { return read }
        guard !NSApp.isActive, let zmx = ZmxRunner.locate() else { return nil }
        return Self.probeForeground(surfaceIDs, zmxPath: zmx)
    }

    /// The records for a project asked to hibernate: one per pane holding an
    /// agent that can leave a handoff. Taken before anything is asked of the
    /// panes, and kept in memory until the project is put away.
    func captureHandoffRecords(for project: ProjectRuntime, surfaceIDs: [UUID],
                               request: HandoffRequest,
                               foreground: [UUID: String]?) -> [HandoffRecord] {
        if case .none = request { return [] }
        guard handoffsEnabled?(project) == true else { return [] }

        var manual = true
        var transcripts: [UUID: Date] = [:]
        if case .automatic(let dates, _) = request {
            manual = false
            transcripts = dates
        }

        // What the hooks, the mod and the cache already say, pane by pane,
        // and ONE search of the harnesses' stores for the rest, together.
        // Asked one at a time, panes sharing a directory were each handed its
        // newest conversation: three panes left three handoffs of one chat.
        var sessions: [UUID: (kind: AgentKind, session: AgentSession)] = [:]
        var lookups: [AgentSessionLookup.Target] = []
        for id in surfaceIDs {
            if let known = knownResumableSession(for: id, using: foreground) {
                sessions[id] = known
            } else if let target = resumeLookupTarget(for: id, using: foreground) {
                lookups.append(target)
            }
        }
        let found = AgentSessionLookup.fallbackSessions(
            for: lookups, claimed: Set(sessions.values.map(\.session.id)))
        for target in lookups {
            if let session = found[target.surface] { sessions[target.surface] = (target.agent, session) }
        }

        let now = Date()
        var records: [HandoffRecord] = []
        for id in surfaceIDs {
            guard let (kind, session) = sessions[id], HandoffCompaction.supports(kind) else { continue }
            let quietFor = transcripts[id].map { now.timeIntervalSince($0) }
            guard HandoffPolicy.writesHandoff(manual: manual, agentQuietFor: quietFor) else {
                ZettyLog.lifecycle.log(
                    "handoff: \(SessionPersistence.shortID(for: id)) skipped, quiet for over a week")
                continue
            }
            let record = HandoffRecord(
                surface: id, agent: kind, sessionID: session.id, cwd: session.cwd,
                accountID: harnessAccount(for: id, kind: kind).accountID, requestedAt: now,
                project: project.settingsKey, title: displayTitle(for: workspace.surface(with: id)))
            records.append(record)
        }
        return records
    }
}

// MARK: - Putting a project away

/// A project whose agents are compacting before it is put away.
struct HibernationInProgress {
    var preparation: HibernationPreparation
    /// Saved when the project is put away, for the panes that compacted.
    var records: [UUID: HandoffRecord]
}

/// Why a project was left awake: the pane that could not hand off, and what
/// stopped it, phrased to follow "Pane x: ".
struct HandoffFailure: Equatable {
    let pane: UUID
    let reason: String
}

extension TerminalViewController {

    /// A project with agents is put away in this order: stop any turn in
    /// progress, have each agent compact its own conversation where the
    /// person can see it, wait for every one, and only then end the
    /// sessions. Until that last step the project is awake, so a failure is
    /// seen while the conversation is still there.
    func beginHibernation(of project: ProjectRuntime, panes: [UUID], records: [HandoffRecord],
                          isAutomatic: Bool) {
        guard let zmx = ZmxRunner.locate() else {
            // Nothing can be typed into a pane without it.
            putAway(project, surfaceIDs: panes, foreground: nil)
            return
        }
        let projectID = project.id
        hibernationsInProgress[projectID] = HibernationInProgress(
            preparation: .init(panes: panes, awaiting: Set(records.map(\.surface)),
                               isAutomatic: isAutomatic),
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.surface, $0) }))
        ZettyLog.lifecycle.log("hibernate: \(project.name) waits on \(records.count) handoff(s)")
        hibernationChromeChanged(for: projectID)

        handoffCompactor.start(records.map { record in
            .init(surface: record.surface, agent: record.agent,
                  session: AgentSession(id: record.sessionID, cwd: record.cwd),
                  configDirectory: harnessConfigDirectory(for: record.surface, kind: record.agent),
                  midTurn: agentDetector.state(for: record.surface).status == .running)
        }, zmxPath: zmx)
    }

    /// `handoffCompactor.onFinished`: a pane compacted, had nothing to, or
    /// could not.
    func handoffCompactionFinished(_ surface: UUID, _ result: HandoffCompaction.Result, title: String?) {
        guard let projectID = hibernationsInProgress.first(where: {
            $0.value.preparation.awaiting.contains(surface)
        })?.key, var inProgress = hibernationsInProgress[projectID] else { return }
        // The conversation's own title, when its harness records one, over
        // the pane's: it names what the record will actually resume. A pane
        // never on screen reported none, and where no hook names a pane's
        // session the pane and the conversation matched to it can differ,
        // which listed one chat under another's name.
        if let title { inProgress.records[surface]?.title = title }
        let outcome = inProgress.preparation.finish(surface, result)
        hibernationsInProgress[projectID] = inProgress
        setNeedsChromeRefresh(tabBar: false, sidebar: true)

        switch outcome {
        case nil:
            break
        case .leftAwake(let failed):
            var reason = "it could not hand off"
            if case .failed(let why) = result { reason = why }
            leaveAwake(projectID, .init(pane: failed, reason: reason))
        case .putAway(let compacted):
            finishHibernation(of: projectID, inProgress, compacted: compacted)
        }
    }

    private func finishHibernation(of projectID: UUID, _ inProgress: HibernationInProgress,
                                   compacted: Set<UUID>) {
        guard let project = workspace.projects.first(where: { $0.id == projectID }),
              !project.isHibernated else {
            cancelHibernation(of: projectID, why: "the project is gone")
            return
        }
        let panes = project.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }
        // Minutes may have passed. A pane added or closed since was never
        // examined, and a project `hibernate-after` picked is not put away
        // from under somebody who has come back to it.
        guard inProgress.preparation.describes(panes) else {
            cancelHibernation(of: projectID, why: "its panes changed")
            return
        }
        guard !(inProgress.preparation.isAutomatic && projectsOnScreen.contains(projectID)) else {
            cancelHibernation(of: projectID, why: "it is on screen again")
            return
        }
        // The records reach the disk only now: a quit or a cancel before
        // this leaves nothing behind.
        for surface in compacted {
            guard let record = inProgress.records[surface], HandoffStore.save(record) else {
                compacted.forEach(HandoffStore.remove)
                leaveAwake(projectID, .init(pane: surface, reason: "its record could not be saved"))
                return
            }
        }
        hibernationsInProgress.removeValue(forKey: projectID)
        ZettyLog.lifecycle.log("hibernate: \(project.name) put away with \(compacted.count) handoff(s)")
        putAway(project, surfaceIDs: panes, foreground: foregroundForHibernation(panes, request: .manual))
    }

    /// A pane could not hand off. The project stays awake, and says so (the
    /// sidebar row and `HandoffBanner`). Kept, so `hibernate-after` does not
    /// try again every minute.
    private func leaveAwake(_ projectID: UUID, _ failure: HandoffFailure) {
        endHibernationAttempt(projectID)
        handoffFailures[projectID] = failure
        if let project = workspace.projects.first(where: { $0.id == projectID }) {
            project.keptAwake = true
            ZettyLog.lifecycle.log("hibernate: \(project.name) left awake, pane "
                + "\(SessionPersistence.shortID(for: failure.pane)): \(failure.reason)")
        }
        hibernationChromeChanged(for: projectID)
    }

    /// Calls a hibernation off while its agents are still compacting. The
    /// project was never put away, so there is nothing to bring back; a
    /// conversation that has already compacted stays compacted.
    func cancelHibernation(of projectID: UUID, why: String) {
        guard hibernationsInProgress[projectID] != nil else { return }
        endHibernationAttempt(projectID)
        ZettyLog.lifecycle.log("hibernate: cancelled, \(why)")
        hibernationChromeChanged(for: projectID)
    }

    private func endHibernationAttempt(_ projectID: UUID) {
        guard let inProgress = hibernationsInProgress.removeValue(forKey: projectID) else { return }
        inProgress.preparation.awaiting.forEach(handoffCompactor.cancel)
    }

    /// Ends every attempt whose project is gone or whose panes changed. From
    /// `reconcileSessions`, the sweep every close path already reaches.
    func cancelOutdatedHibernations() {
        for (projectID, inProgress) in hibernationsInProgress {
            let panes = workspace.projects.first { $0.id == projectID }?
                .tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }
            if panes.map(inProgress.preparation.describes) != true {
                cancelHibernation(of: projectID, why: "its panes changed")
            }
        }
        handoffFailures = handoffFailures.filter { projectID, _ in
            workspace.projects.contains { $0.id == projectID }
        }
    }

    /// The sidebar row always, and the banner when the project is the one on
    /// screen. Coalesced: a compaction finishing is machine-driven.
    private func hibernationChromeChanged(for projectID: UUID) {
        setNeedsChromeRefresh(tabBar: false, sidebar: true)
        guard !tileMode, workspace.activeProject.id == projectID else { return }
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() { view.window?.makeFirstResponder(focused) }
    }

    /// The banner's Dismiss.
    func dismissHandoffFailure(for projectID: UUID) {
        guard handoffFailures.removeValue(forKey: projectID) != nil else { return }
        hibernationChromeChanged(for: projectID)
    }

    /// The banner for the active project, when it has something to say.
    func makeHandoffBanner() -> HandoffBanner? {
        let project = workspace.activeProject
        let projectID = project.id
        if let inProgress = hibernationsInProgress[projectID] {
            let count = inProgress.records.count
            return HandoffBanner(.writing(agentPanes: count), onPrimary: { [weak self] in
                self?.cancelHibernation(of: projectID, why: "cancelled from the banner")
            })
        }
        if let failure = handoffFailures[projectID] {
            return HandoffBanner(
                .failed(pane: SessionPersistence.shortID(for: failure.pane), reason: failure.reason),
                onPrimary: { [weak self] in
                    guard let self, let project = workspace.projects.first(where: { $0.id == projectID })
                    else { return }
                    hibernateProject(project, handoffs: .none)
                },
                onDismiss: { [weak self] in self?.dismissHandoffFailure(for: projectID) })
        }
        return nil
    }
}

// MARK: - Waking

extension TerminalViewController {

    /// Queues each pane's way back, before a woken project's panes spawn.
    /// Delivered lazily like every startup command, so a tab nobody opens
    /// spends no turn.
    ///
    /// This is the wake that puts the whole layout back, each agent pane
    /// resuming its own handoff: `zetty wake`, a CLI verb or a tile waking a
    /// project for a pane it is about to drive. A wake picked on the
    /// hibernated screen has already decided what its one pane starts with.
    func queueHandoffWakes(for project: ProjectRuntime) {
        let alreadyDecided = singlePaneWakes.remove(project.id) != nil
        for surface in project.tabList.trees.flatMap({ $0.layout.surfaces }) {
            if !alreadyDecided, let record = HandoffStore.record(for: surface.id) {
                queueHandoffWake(record, surface: surface)
            }
            // A pick is for this wake only, handoff or not: left behind, it
            // would decide a wake months from now.
            handoffWakeChoices.removeValue(forKey: surface.id)
        }
    }

    private func queueHandoffWake(_ record: HandoffRecord, surface: Surface) {
        let id = surface.id
        let login = AgentAccountResolver.resumeLogin(
            agentID: record.agent.rawValue, runningAccountID: record.accountID,
            spawnedAccountID: surface.accountID, accounts: accountsProvider?() ?? [],
            home: NSHomeDirectory())
        // Picked for this wake, or remembered from one a quit interrupted.
        let choice = handoffWakeChoices.removeValue(forKey: id) ?? record.wake ?? .resume
        let plan = HandoffWake.plan(record: record, choice: choice, login: login)
        ZettyLog.lifecycle.log("handoff: \(SessionPersistence.shortID(for: id)) wakes \(plan.logName)")
        switch plan {
        case .resume(let command), .fresh(let command):
            // Guarded like a recovery resume: never typed into a live agent.
            queueStartupCommands([id: command], asAgentResume: true)
            handoffWakeSurfaces.insert(id)
            handoffBootSurfaces[id] = choice == .fresh ? Self.startingAgentMessage : Self.resumingHandoffMessage
            // A wake line waits for its tab to be opened, and a quit loses
            // it: the record is what types it again, the way it was picked.
            // It also stops being a handoff waiting to be picked.
            if record.wake != choice {
                var chosen = record
                chosen.wake = choice
                HandoffStore.save(chosen)
            }
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

    /// What `zetty status` says about a pane's handoff: `writing` while its
    /// project waits on it to be put away, `failed` on the pane that left
    /// its project awake, `ready` on a hibernated pane that will wake by
    /// resuming its compacted conversation.
    func handoffState(for surfaceID: UUID, in project: ProjectRuntime) -> String? {
        if let inProgress = hibernationsInProgress[project.id] {
            return inProgress.preparation.isWriting(surfaceID) ? "writing" : nil
        }
        if handoffFailures[project.id]?.pane == surfaceID { return "failed" }
        guard project.isHibernated else { return nil }
        return HandoffStore.record(for: surfaceID) != nil ? "ready" : nil
    }

    /// The woken pane's agent is back: its record is spent.
    func consumeHandoff(_ surfaceID: UUID) {
        guard handoffWakeSurfaces.remove(surfaceID) != nil else { return }
        HandoffStore.remove(surfaceID)
        ZettyLog.lifecycle.log("handoff: \(SessionPersistence.shortID(for: surfaceID)) consumed")
    }

    /// How long after its wake line is queued a record is consumed on the
    /// probe's word alone. Hooks are optional, and by then the harness has
    /// long since started.
    static let handoffConsumeDelay: TimeInterval = 60

    /// The backstop for a pane whose harness never reports through a hook.
    /// It takes its own reading: the poll behind `foregroundBySurface` stops
    /// while Zetty is in the background, and a record left unconsumed has
    /// its wake line typed into the pane again at the next launch.
    func scheduleHandoffConsume(_ surfaceID: UUID) {
        guard handoffWakeSurfaces.contains(surfaceID), let zmx = ZmxRunner.locate() else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.handoffConsumeDelay) {
            let running = Self.probeForeground([surfaceID], zmxPath: zmx)?[surfaceID]
            guard let running, AgentKind(rawValue: running).map(HandoffCompaction.supports) == true
            else { return }
            DispatchQueue.main.async { [weak self] in self?.consumeHandoff(surfaceID) }
        }
    }

    /// A quit loses queued wake lines; the records say which are still due.
    /// Called once at launch, after accounts and settings are loaded.
    ///
    /// Only a record marked as on its way back (`wake`) is acted on. One
    /// without is a handoff waiting to be picked, in a hibernated project or
    /// in an awake one that has not started it yet.
    func restoreHandoffState() {
        for record in HandoffStore.allRecords() where record.wake != nil {
            // A pane that is gone is the sweep's.
            guard let project = workspace.project(containing: record.surface),
                  let surface = workspace.surface(with: record.surface),
                  !project.isHibernated else { continue }
            // A restart-recovery resume for the same pane describes something
            // later and wins; guarded delivery skips a pane whose agent is in
            // fact already running.
            guard !hasPendingStartupCommand(for: record.surface) else {
                HandoffStore.remove(record.surface)
                continue
            }
            queueHandoffWake(record, surface: surface)
        }
    }
}

// MARK: - Waking as one pane

extension TerminalViewController {
    /// What a pane's cover says while its agent starts; see
    /// `coverPaneWhileAgentBoots`.
    static let resumingHandoffMessage = "Resuming handoff…"
    static let startingAgentMessage = "Starting agent…"
}

/// What the one pane of a waking project starts with.
enum HandoffStart {
    case handoff(HandoffRecord)
    /// A new conversation in this harness.
    case fresh(AgentKind)
    case shell
}

extension TerminalViewController {

    /// The handoffs waiting to be picked in a project, newest first: every
    /// one of a hibernated project's, and whatever an awake one has not
    /// started yet. One directory listing and a small file each.
    func waitingHandoffs(for project: ProjectRuntime) -> [HandoffRecord] {
        let panes = Set(project.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) })
        return HandoffStore.allRecords()
            .filter { $0.isWaiting(in: project.settingsKey, panes: panes) }
            .sorted { ($0.requestedAt, $0.surface.uuidString) > ($1.requestedAt, $1.surface.uuidString) }
    }

    /// Throws a waiting handoff away: from the hibernated project's screen,
    /// or from the chooser a new tab or split shows. Only the record goes.
    /// The compacted conversation is the harness's and stays in its history,
    /// so this is not asked about first.
    func deleteHandoff(_ record: HandoffRecord) {
        HandoffStore.remove(record.surface)
        ZettyLog.lifecycle.log("handoff: \(SessionPersistence.shortID(for: record.surface)) deleted")
        setNeedsChromeRefresh(tabBar: false, sidebar: true)
        // The hibernated screen lists them, and may now have none to list.
        guard !tileMode, workspace.activeProject.isHibernated else { return }
        rebuildSurfaceNodeView()
    }

    /// Wakes a hibernated project as ONE pane, started as picked on its
    /// screen. Its handoffs are not put back as a layout (Glen, 2026-10-08):
    /// the one picked starts here and the rest wait, offered again by the
    /// agent chooser whenever a tab or split is added.
    func wakeProject(_ project: ProjectRuntime, startingWith start: HandoffStart) {
        guard project.isHibernated else { return }
        var picked: HandoffRecord?
        if case .handoff(let record) = start { picked = record }
        // The picked handoff's own pane when the layout still has it, so its
        // title and directory carry over.
        let pane = project.tabList.collapse(toSurface: picked?.surface)

        // A handoff filed under the surviving pane that was not the one
        // picked would be overwritten the next time this pane hands off.
        for record in waitingHandoffs(for: project)
        where record.surface == pane && record.surface != picked?.surface {
            HandoffStore.remove(record.surface)
            HandoffStore.save(record.rekeyed())
        }

        switch start {
        case .handoff(let record):
            let login = AgentAccountResolver.resumeLogin(
                agentID: record.agent.rawValue, runningAccountID: record.accountID,
                spawnedAccountID: workspace.surface(with: pane)?.accountID,
                accounts: accountsProvider?() ?? [], home: NSHomeDirectory())
            if let command = HandoffWake.command(record: record, login: login) {
                queueStartupCommands([pane: command], asAgentResume: true)
                handoffBootSurfaces[pane] = Self.resumingHandoffMessage
                if login != .inherited, let account = record.accountID {
                    holdRunningAccountForResume(surfaceID: pane, accountID: account)
                }
            }
            HandoffStore.remove(record.surface)
        case .fresh(let kind):
            if let command = SpawnableAgent.byID(kind.rawValue)?.defaultCommand {
                queueStartupCommands([pane: command])
                handoffBootSurfaces[pane] = Self.startingAgentMessage
            }
        case .shell:
            break
        }
        ZettyLog.lifecycle.log("handoff: \(project.name) wakes as one pane")
        singlePaneWakes.insert(project.id)
        wakeProject(project)
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
        // Typing into a project that is on its way out is a change of mind.
        // After this key is delivered: the cancel rebuilds the pane area.
        guard hibernationsInProgress[project.id] != nil else { return }
        let projectID = project.id
        DispatchQueue.main.async { [weak self] in
            self?.cancelHibernation(of: projectID, why: "it was typed into")
        }
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
            if hibernationsInProgress[project.id] != nil { continue }   // already on its way
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
