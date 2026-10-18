import AppKit
import ZettyCore

/// What typing a handoff's request into its agent needs, off the main thread.
struct AgentHandoffTyping: Sendable {
    let surfaceID: UUID
    let session: String
    let agent: AgentKind
    let midTurn: Bool
    let prompt: String
    let zmx: String

    /// Types the request; nil when it was submitted, else why not. Blocking.
    func submit() -> String? {
        let typed = ZmxRunner.submit(prompt, session: session, agent: agent, midTurn: midTurn,
                                     zmxPath: zmx, isCancelled: { false })
        if case .failed(let reason) = typed { return reason }
        return nil
    }
}

/// A pane handed to a fresh session, waiting on the brief its agent writes.
struct AgentHandoffJob {
    let target: AgentHandoff.Target
    let briefPath: String
    /// The harness writing the brief, which is the one that quits.
    let agent: AgentKind
    /// Its conversation, so its own hook events are never taken for the new
    /// session's.
    let oldSession: String?
    let deadline: Date
    var timer: Timer?
    /// The brief's size at the last tick, and how many ticks it has held it.
    var lastSize: UInt64?
    var steadyTicks = 0
    var screenReadInFlight = false
    var screenAtRest = false
}

// MARK: - Handing a pane's work to a fresh session

/// The flow behind the gutter's handoff button, `zetty handoff` and the mod's
/// `/z-handoff` (`AgentHandoff`):
///
/// 1. The agent is asked to write its brief: typed into its box like
///    hibernate's `/compact`, or, when it asked itself, submitted by the mod.
/// 2. A timer waits for the file to exist, hold its size, and the agent to
///    be at rest.
/// 3. `relaunchAgent`, the ⟳ restart's body, covers the pane, quits the agent
///    and types the launch line, under the target login.
/// 4. The new session's hook events delete the brief after its first turn.
extension TerminalViewController {

    /// How a handoff began.
    enum AgentHandoffStart {
        /// The agent that asked submits this itself.
        case asked(prompt: String)
        /// Its request is to be typed into the pane by the caller.
        case started(AgentHandoffTyping)
        case refused(String)
        /// The agent was mid-turn and `allowRunning` said no.
        case declined
    }

    /// Ticks of an unchanged brief before a Claude whose hooks have said
    /// nothing is taken to have finished it. With hooks, at rest is their
    /// word; without, the box looks the same while Claude works.
    private static let handoffSteadyTicksWithoutHooks = 5

    /// Whether the pane's gutter offers a handoff: a Claude or Codex the
    /// probe sees, which can be told to quit. No session id is needed, since
    /// nothing is resumed.
    func canHandOffAgent(surfaceID: UUID) -> Bool {
        guard let kind = probedResumableKind(for: surfaceID) else { return false }
        return AgentResume.exitCommand(for: kind) != nil
    }

    /// The handoff menu: a fresh session on the same login, then every
    /// target. `name` is what `AgentHandoff.resolve` takes.
    func agentHandoffMenu(for surfaceID: UUID) -> [(title: String, name: String?)] {
        [("Fresh Session, Same Login", nil)]
            + AgentHandoff.targets(accounts: accountsProvider?() ?? []).map { ($0.title, $0.name) }
    }

    /// The gutter button's pick. A turn in progress is asked about first.
    func handOffAgentPane(surfaceID: UUID, to name: String?) {
        let started = startAgentHandoff(surfaceID: surfaceID, to: name, asking: false) { [weak self] in
            self?.confirmInterruptingForHandoff(surfaceID) ?? false
        }
        switch started {
        case .refused(let message):
            presentAgentRestartFailure(message, title: "Could not hand off")
        case .started(let typing):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let reason = typing.submit() else { return }
                DispatchQueue.main.async {
                    guard let self, self.cancelAgentHandoff(surfaceID, why: reason) else { return }
                    self.presentAgentRestartFailure("Nothing was handed off: \(reason).", title: "Could not hand off")
                }
            }
        case .asked, .declined:
            break
        }
    }

    /// What `zetty handoff` answers before anything is typed.
    enum AgentHandoffAnswer {
        /// `--self`: the prompt the asking agent submits.
        case prompt(String)
        /// The request still has to be typed, off the main thread
        /// (`AgentHandoffTyping.submit`), so a refusal reaches the caller.
        case typing(AgentHandoffTyping)
        case cancelled
    }

    /// CLI `handoff`: errors as text, `force` in place of the dialog.
    func handOffAgent(target: PaneSelector, to name: String?, asking: Bool,
                      force: Bool, cancel: Bool) -> Result<AgentHandoffAnswer, ControlError> {
        let pane: StatusSnapshot.Pane
        do { pane = try target.resolve(in: statusSnapshot().panes) } catch {
            return .failure(.protocolError(error.localizedDescription))
        }
        guard let surface = surface(withShortID: pane.id) else {
            return .failure(.protocolError("pane \(pane.id) not found"))
        }
        if cancel {
            return cancelAgentHandoff(surface.id, why: "cancelled from the CLI")
                ? .success(.cancelled)
                : .failure(.protocolError("pane \(pane.id) has no handoff waiting on its brief"))
        }
        switch startAgentHandoff(surfaceID: surface.id, to: name, asking: asking, allowRunning: { force }) {
        case .asked(let prompt): return .success(.prompt(prompt))
        case .started(let typing): return .success(.typing(typing))
        case .refused(let message): return .failure(.protocolError(message))
        case .declined:
            return .failure(.protocolError(
                "the agent in pane \(pane.id) is running a turn — pass --force to interrupt it and hand off"))
        }
    }

    private func startAgentHandoff(surfaceID: UUID, to name: String?, asking: Bool,
                                   allowRunning: () -> Bool) -> AgentHandoffStart {
        guard agentHandoffs[surfaceID] == nil else {
            return .refused("This pane is already being handed off; its agent is writing the brief.")
        }
        guard agentRestartTimers[surfaceID] == nil else {
            return .refused("This pane's agent is restarting.")
        }
        let session = SessionPersistence.sessionName(for: surfaceID)
        // A CLI request's own reading first: the cached map stops updating
        // while Zetty is not frontmost, which is when scripts call it.
        let foreground = BusyPaneGate.command(session: session, reading: cliForegroundReading,
                                              cached: foregroundBySurface[surfaceID])
        guard let kind = probedResumableKind(for: surfaceID, using: foreground.map { [surfaceID: $0] } ?? [:]),
              AgentResume.exitCommand(for: kind) != nil else {
            return .refused("No Claude or Codex is running in this pane.")
        }
        guard workspace.surface(with: surfaceID) != nil else { return .refused("The pane is gone.") }
        guard let zmx = ZmxRunner.locate(), lastSessionPIDs[session] != nil
                || ZmxRunner.sessionPIDs(zmxPath: zmx)[session] != nil else {
            return .refused("Handing off needs preserve-sessions, so Zetty can drive and watch the agent.")
        }
        let target: AgentHandoff.Target
        switch AgentHandoff.resolve(name, current: kind,
                                    currentAccountID: harnessAccount(for: surfaceID, kind: kind).accountID,
                                    accounts: accountsProvider?() ?? []) {
        case .success(let resolved): target = resolved
        case .failure(let error): return .refused(error.localizedDescription)
        }
        // The asking agent is running the command that asked, which is its
        // turn: it is not refused for that, and nothing is typed into it.
        let midTurn = !asking && agentDetector.state(for: surfaceID).status == .running
        if midTurn, !allowRunning() { return .declined }

        let briefPath = AgentHandoff.briefPath(for: surfaceID, home: NSHomeDirectory())
        let fm = FileManager.default
        // Private, like the hibernation handoffs: a brief holds whatever the
        // conversation did, and `~/.zetty` is readable by every account.
        let directory = (briefPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        // A brief left from an earlier handoff of this pane is not this one's.
        try? fm.removeItem(atPath: briefPath)
        pendingBriefs.removeValue(forKey: surfaceID)
        Self.sweepStaleHandoffBriefs()

        var job = AgentHandoffJob(target: target, briefPath: briefPath, agent: kind,
                                  oldSession: agentDetector.state(for: surfaceID).session?.id,
                                  deadline: Date() + AgentHandoff.writeTimeout)
        job.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHandoffBrief(surfaceID, zmx: zmx) }
        }
        agentHandoffs[surfaceID] = job
        let pane = SessionPersistence.shortID(for: surfaceID)
        ZettyLog.lifecycle.log("agent handoff: \(pane) to \(target.agent.rawValue)/\(target.accountID)")

        let prompt = AgentHandoff.writePrompt(briefPath: briefPath)
        if asking { return .asked(prompt: prompt) }
        return .started(AgentHandoffTyping(surfaceID: surfaceID, session: session, agent: kind,
                                           midTurn: midTurn, prompt: prompt, zmx: zmx))
    }

    /// Stops a handoff still waiting on its brief. The agent keeps running;
    /// a brief it writes anyway is swept a day later.
    @discardableResult
    func cancelAgentHandoff(_ surfaceID: UUID, why: String) -> Bool {
        guard let job = agentHandoffs.removeValue(forKey: surfaceID) else { return false }
        job.timer?.invalidate()
        ZettyLog.lifecycle.log("agent handoff: \(SessionPersistence.shortID(for: surfaceID)) called off (\(why))")
        return true
    }

    /// One tick of the wait for the brief.
    private func checkHandoffBrief(_ surfaceID: UUID, zmx: String) {
        guard var job = agentHandoffs[surfaceID] else { return }
        guard Date() < job.deadline else {
            cancelAgentHandoff(surfaceID, why: "no brief")
            presentAgentRestartFailure(
                "\(job.agent.displayName) did not write its brief within \(Int(AgentHandoff.writeTimeout / 60)) "
                    + "minutes, so it was left running.", title: "Could not hand off")
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: job.briefPath))?[.size] as? UInt64
        guard let size, size > 0 else {
            job.lastSize = nil
            job.steadyTicks = 0
            agentHandoffs[surfaceID] = job
            return
        }
        if size != job.lastSize { job.screenAtRest = false }
        job.steadyTicks = size == job.lastSize ? job.steadyTicks + 1 : 0
        job.lastSize = size
        agentHandoffs[surfaceID] = job
        guard job.steadyTicks >= 1 else { return }

        // Claude's hooks say whether its turn is over; its box looks the
        // same either way. Codex's hook cannot say, and its screen can.
        let status = agentDetector.state(for: surfaceID).status
        if job.agent == .claude, let status {
            guard status != .running else { return }
            return proceedWithAgentHandoff(surfaceID, zmx: zmx)
        }
        if job.agent == .claude, job.steadyTicks < Self.handoffSteadyTicksWithoutHooks { return }
        if job.screenAtRest { return proceedWithAgentHandoff(surfaceID, zmx: zmx) }
        guard !job.screenReadInFlight else { return }
        agentHandoffs[surfaceID]?.screenReadInFlight = true
        let session = SessionPersistence.sessionName(for: surfaceID)
        let agent = job.agent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ready = ZmxRunner.historyVT(session: session, zmxPath: zmx, timeout: 2).map {
                PromptBox.readiness(vtScreen: PromptBox.tail(of: $0), agent: agent) == .ready
            } ?? false
            DispatchQueue.main.async {
                self?.agentHandoffs[surfaceID]?.screenReadInFlight = false
                self?.agentHandoffs[surfaceID]?.screenAtRest = ready
            }
        }
    }

    /// The brief is written: quit the agent and start the new session on it.
    private func proceedWithAgentHandoff(_ surfaceID: UUID, zmx: String) {
        guard let job = agentHandoffs.removeValue(forKey: surfaceID) else { return }
        job.timer?.invalidate()
        let session = SessionPersistence.sessionName(for: surfaceID)
        guard let surface = workspace.surface(with: surfaceID),
              let exit = AgentResume.exitCommand(for: job.agent),
              let sessionPID = lastSessionPIDs[session] ?? ZmxRunner.sessionPIDs(zmxPath: zmx)[session]
        else {
            return presentAgentRestartFailure("The pane's session could not be found.", title: "Could not hand off")
        }
        let accounts = accountsProvider?() ?? []
        let login = AgentAccountResolver.resumeLogin(
            agentID: job.target.agent.rawValue, runningAccountID: job.target.accountID,
            spawnedAccountID: surface.accountID, accounts: accounts, home: NSHomeDirectory())
        // The shell reports its directory as it changes; the spawn one is the fallback.
        let cwd = PaneCwdStore.read(surfaceID) ?? surface.workingDir
        guard let line = AgentHandoff.launchLine(agent: job.target.agent, login: login, cwd: cwd,
                                                 briefPath: job.briefPath) else {
            return presentAgentRestartFailure("That harness cannot be started on a brief.", title: "Could not hand off")
        }
        pendingBriefs[surfaceID] = PendingBrief(path: job.briefPath, agent: job.target.agent)
        // The old conversation's own events (its end, mostly) must not be
        // read as the new one's.
        handoffOldSessions[surfaceID] = job.oldSession
        let newAgent = job.target.agent
        relaunchAgent(
            surfaceID: surfaceID, sessionPID: sessionPID, agent: job.agent, exit: exit, line: line,
            returning: newAgent, marker: AgentHandoff.launchMarker(briefPath: job.briefPath),
            session: session, zmx: zmx,
            notQuit: "\(job.agent.displayName) did not quit, so no new session was started. "
                + "Its brief is at \(job.briefPath).",
            notBack: "The new \(newAgent.displayName) session was started but has not come up yet.",
            failureTitle: "Could not hand off"
        ) { [weak self] ok in
            guard let self else { return }
            if !ok, self.probedResumableKind(for: surfaceID) == job.agent {
                // Still the old agent: there is no new session to read it.
                self.pendingBriefs.removeValue(forKey: surfaceID)
                return
            }
            // The chip follows the new login now; its hooks confirm it.
            self.updateSurfaceAnywhere(surfaceID) {
                $0.runningAccountID = AgentAccountResolver.runningOverride(reported: job.target.accountID,
                                                                           spawned: $0.accountID)
            }
            self.forgetResumeSession(for: surfaceID)
            self.setNeedsChromeRefresh(tabBar: true, sidebar: true)
        }
    }

    /// Hook events from a pane whose new session has been told to read its
    /// brief: deleted once that session's first turn is over.
    func observeHandoffBrief(_ event: AgentEvent, surfaceID: UUID) {
        guard var brief = pendingBriefs[surfaceID], event.agent == brief.agent else { return }
        // The old session quitting, mid-relaunch, is not the new one ending.
        if agentRestartTimers[surfaceID] != nil, event.event == .ended { return }
        if let old = handoffOldSessions[surfaceID], let session = event.session, session == old { return }
        let done = brief.observe(event.event)
        guard done else { return pendingBriefs[surfaceID] = brief }
        pendingBriefs.removeValue(forKey: surfaceID)
        handoffOldSessions.removeValue(forKey: surfaceID)
        try? FileManager.default.removeItem(atPath: brief.path)
        ZettyLog.lifecycle.log("agent handoff: \(SessionPersistence.shortID(for: surfaceID)) brief read, removed")
    }

    /// Asks before a handoff interrupts a turn in progress.
    private func confirmInterruptingForHandoff(_ surfaceID: UUID) -> Bool {
        guard !isServingControlRequest else { return false }
        let name = probedResumableKind(for: surfaceID)?.displayName ?? "The agent"
        let alert = NSAlert()
        alert.messageText = "Hand Off Now?"
        alert.informativeText = "\(name) is working. Handing off stops its turn first, then asks it to write the brief."
        alert.addButton(withTitle: "Hand Off")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Removes briefs older than `AgentHandoff.staleAfter`: their session
    /// never took a turn, hooks are off, or the handoff failed after writing.
    static func sweepStaleHandoffBriefs() {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".zetty/transfers")
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            else { return }
            let cutoff = Date().addingTimeInterval(-AgentHandoff.staleAfter)
            for file in files where file.pathExtension == "md" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff { try? fm.removeItem(at: file) }
            }
        }
    }
}
