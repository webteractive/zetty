import Foundation

/// A probe that never resolves a command — used when detection is driven purely
/// by harness hooks (the current mechanism) rather than foreground-process scans.
public struct NullForegroundProcessProbe: ForegroundProcessProbe {
    public init() {}
    public func foregroundCommand(forPTY fd: Int32) -> String? { nil }
}

public final class AgentDetector {
    private let probe: ForegroundProcessProbe
    private let board = AgentStatusBoard()

    public init(probe: ForegroundProcessProbe = NullForegroundProcessProbe()) {
        self.probe = probe
    }

    public func state(for session: UUID) -> AgentState {
        board.state(for: session)
    }

    /// Applies one timestamped report (mod snapshot, hook event or terminal
    /// signal) to the pane `session`. See `AgentStatusBoard` for the rules.
    @discardableResult
    public func apply(report: AgentReport, session: UUID, replay: Bool = false,
                      now: TimeInterval) -> AgentApplyResult {
        board.apply(report, to: session, replay: replay, now: now)
    }

    /// Feeds the foreground probe's reading for the pane (`nil` = not probed).
    @discardableResult
    public func observeForeground(_ command: String?, session: UUID, now: TimeInterval) -> AgentApplyResult {
        board.observeForeground(command, pane: session, now: now)
    }

    /// A finish seen outside the reports; true = post the finished banner.
    public func noteFinished(session: UUID, at: TimeInterval) -> Bool {
        board.noteFinished(pane: session, at: at)
    }

    /// Applies a harness-hook `AgentEvent` stamped with `now` (each call a
    /// hair newer than the pane's last report, so a batch read in one poll
    /// keeps its order) and returns the new state.
    @discardableResult
    public func apply(event: AgentEvent, session: UUID, now: TimeInterval) -> AgentState {
        lastForwarded = max(now, lastForwarded + 0.000_001)
        var report = event.legacyReport
        report.at = lastForwarded
        return board.apply(report, to: session, replay: false, now: now).state
    }
    private var lastForwarded: TimeInterval = 0

    /// Clears a session's state (e.g. when its surface closes).
    public func clear(session: UUID) {
        board.clear(pane: session)
    }

    @discardableResult
    public func update(
        session: UUID,
        ptyFD: Int32,
        lastOutputAt: TimeInterval?,
        hookEvent: HookEvent?,
        now: TimeInterval
    ) -> AgentState {
        let command = probe.foregroundCommand(forPTY: ptyFD)
        let descriptor = command.flatMap(AgentRegistry.match(command:))
        let observation = AgentObservation(
            descriptor: descriptor,
            lastOutputAt: lastOutputAt,
            hookEvent: hookEvent,
            now: now
        )
        let next = AgentStateMachine.reduce(previous: state(for: session), observation: observation)
        board.overwrite(next, pane: session)
        return next
    }
}

private extension AgentEvent {
    var legacyReport: AgentReport {
        let state: AgentReport.State
        switch event {
        case .running: state = .running
        case .idle: state = .idle
        case .needsAttention: state = .needsAttention
        case .ended: state = .ended
        }
        return AgentReport(source: .hook, agent: agent, state: state, at: 0,
                           session: session.map { AgentSession(id: $0, cwd: cwd) })
    }
}
