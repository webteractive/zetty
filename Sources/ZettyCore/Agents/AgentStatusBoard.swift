import Foundation

/// The one reducer for agent status, per pane (spec 2026-11-14, section 1).
///
/// - The newest report wins, whatever its source; a tie goes to the mod.
///   Times make the mod and the hook for the same moment agree, and a late
///   duplicate is older and loses, so the dot never flickers between them.
/// - The foreground probe gates liveness: two consecutive probes that see the
///   shell at its prompt end the agent, whatever it last reported. A pane the
///   probe doesn't cover is decided by reports alone.
/// - Replay (the event log read at launch) restores state quietly and ages a
///   running or waiting report older than `replayMaxAge` to idle.
/// - "Needs you" and "finished" each post once per moment: repeats within
///   `collapseWindow` of the last one posted collapse into it.
public final class AgentStatusBoard {

    public static let collapseWindow: TimeInterval = 2
    public static let replayMaxAge: TimeInterval = 900
    public static let probeMissesToEnd = 2

    private struct Pane {
        var latest: AgentReport?
        var state = AgentState()
        var lastAttentionAt: TimeInterval?
        var lastFinishedAt: TimeInterval?
        var misses = 0
    }

    private var panes: [UUID: Pane] = [:]

    public init() {}

    public func state(for pane: UUID) -> AgentState {
        panes[pane]?.state ?? AgentState()
    }

    @discardableResult
    public func apply(_ report: AgentReport, to id: UUID, replay: Bool, now: TimeInterval) -> AgentApplyResult {
        var pane = panes[id] ?? Pane()
        let previous = pane.state.status
        guard report.supersedes(pane.latest) else {
            return AgentApplyResult(accepted: false, previous: previous, state: pane.state)
        }
        pane.latest = report

        var raised = false
        var finished = false
        switch report.state {
        case .ended:
            pane.state = AgentState()
        case .running, .idle, .needsAttention:
            var status = Self.status(report.state)
            if replay, status != .idle, now - report.at > Self.replayMaxAge {
                status = .idle
            }
            pane.state = AgentState(kind: report.agent, status: status,
                                    session: report.session ?? pane.state.session)
            if !replay, status == .needsAttention, !Self.within(pane.lastAttentionAt, of: report.at) {
                raised = true
                pane.lastAttentionAt = report.at
            }
            if !replay, status == .idle, previous == .running, !Self.within(pane.lastFinishedAt, of: report.at) {
                finished = true
                pane.lastFinishedAt = report.at
            }
        }
        panes[id] = pane
        return AgentApplyResult(accepted: true, previous: previous, state: pane.state,
                                raisedAttention: raised, finished: finished)
    }

    /// Feeds one probe reading. `nil`: the pane isn't probed (no-op). `""`:
    /// the shell is at its prompt, a miss. Any other command, agent or not, is
    /// presence (an agent's own tool run puts e.g. `npm` in the foreground).
    @discardableResult
    public func observeForeground(_ command: String?, pane id: UUID, now: TimeInterval) -> AgentApplyResult {
        guard var pane = panes[id] else {
            return AgentApplyResult(accepted: false, previous: nil, state: AgentState())
        }
        let previous = pane.state.status
        guard let command else {
            return AgentApplyResult(accepted: false, previous: previous, state: pane.state)
        }
        guard command.isEmpty else {
            pane.misses = 0
            panes[id] = pane
            return AgentApplyResult(accepted: false, previous: previous, state: pane.state)
        }
        guard pane.state.kind != nil else {
            return AgentApplyResult(accepted: false, previous: previous, state: pane.state)
        }
        pane.misses += 1
        var accepted = false
        if pane.misses >= Self.probeMissesToEnd {
            // Ended at `now`, so a report from before the agent died (a mod
            // snapshot re-read every poll) can't bring it back.
            pane.latest = AgentReport(source: .terminal, agent: pane.state.kind ?? .claude,
                                      state: .ended, at: now)
            pane.state = AgentState()
            pane.misses = 0
            accepted = true
        }
        panes[id] = pane
        return AgentApplyResult(accepted: accepted, previous: previous, state: pane.state)
    }

    /// A finish seen outside the reports (a terminal notification or bell).
    /// True when the finished banner should be posted.
    public func noteFinished(pane id: UUID, at: TimeInterval) -> Bool {
        var pane = panes[id] ?? Pane()
        guard !Self.within(pane.lastFinishedAt, of: at) else { return false }
        pane.lastFinishedAt = at
        panes[id] = pane
        return true
    }

    public func clear(pane id: UUID) {
        panes[id] = nil
    }

    /// For `AgentDetector`'s output-heuristic path, which predates reports.
    func overwrite(_ state: AgentState, pane id: UUID) {
        var pane = panes[id] ?? Pane()
        pane.state = state
        panes[id] = pane
    }

    private static func within(_ last: TimeInterval?, of at: TimeInterval) -> Bool {
        guard let last else { return false }
        return abs(at - last) <= collapseWindow
    }

    private static func status(_ state: AgentReport.State) -> AgentStatus {
        switch state {
        case .running: return .running
        case .needsAttention: return .needsAttention
        case .idle, .ended: return .idle
        }
    }
}
