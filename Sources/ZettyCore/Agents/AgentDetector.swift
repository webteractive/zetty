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

    /// Forgets every session not in `ids` (closed panes, hibernated projects).
    public func prune(keeping ids: Set<UUID>) {
        board.prune(keeping: ids)
    }

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
