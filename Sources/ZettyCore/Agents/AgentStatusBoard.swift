import Foundation

/// The one reducer for agent status, per pane (spec 2026-11-14, section 1).
///
/// - The newest report wins, whatever its source; a tie goes to the mod.
///   Times make the mod and the hook for the same moment agree, and a late
///   duplicate is older and loses, so the dot never flickers between them.
/// - The foreground probe gates liveness: two consecutive probes that see the
///   shell at its prompt end the agent, whatever it last reported. A pane the
///   probe doesn't cover is decided by reports alone.
/// - Replay (the event log read at launch) restores state quietly. A running
///   or waiting report older than `replayMaxAge` is kept until the first probe:
///   an agent still in the foreground confirms it (a prompt left over lunch is
///   still pending), an unprobed pane ages it to idle, and the probe gate ends
///   a dead one. A report with no time (an older helper's line) ages at once.
/// - A waiting pane stays waiting until the loop that asked moves on: a tool
///   call from a parallel subagent doesn't resolve another loop's prompt.
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
        /// The loops with a prompt still pending ("main" or a subagent id).
        var waitingLoops: Set<String> = []
        /// Restored from replay older than `replayMaxAge`: kept until the
        /// probe says whether the agent is still there (then confirmed), or
        /// that the pane isn't probed at all (then aged to idle).
        var ageOnProbe = false
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
            // The other source's report of the same prompt: older, so it
            // loses, but the loop it names is still waiting.
            if report.state == .needsAttention, previous == .needsAttention {
                pane.waitingLoops.insert(report.loop ?? "main")
                panes[id] = pane
            }
            return AgentApplyResult(accepted: false, previous: previous, state: pane.state)
        }
        pane.latest = report
        pane.ageOnProbe = false

        var raised = false
        var finished = false
        switch report.state {
        case .ended:
            pane.state = AgentState()
            pane.waitingLoops = []
        case .running, .idle, .needsAttention:
            var status = Self.status(report.state)
            if replay, status != .idle, now - max(report.at, report.confirmedAt ?? 0) > Self.replayMaxAge {
                // A line with no time is never trusted; anything else waits
                // for the probe to say whether its agent is still there.
                if report.at == 0 { status = .idle } else { pane.ageOnProbe = true }
            }
            switch status {
            case .needsAttention:
                pane.waitingLoops.insert(report.loop ?? "main")
            case .running where previous == .needsAttention:
                // A tool call resolves only its own loop's prompt; a report
                // with no loop (a new prompt) resolves them all.
                if let loop = report.loop { pane.waitingLoops.remove(loop) } else { pane.waitingLoops = [] }
                if !pane.waitingLoops.isEmpty { status = .needsAttention }
            default:
                pane.waitingLoops = []
            }
            pane.state = AgentState(kind: report.agent, status: status,
                                    session: report.session ?? pane.state.session)
            if !replay, status == .needsAttention, report.state == .needsAttention,
               !Self.within(pane.lastAttentionAt, of: report.at) {
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
            // Not probed: nothing will ever confirm an old replayed state.
            guard pane.ageOnProbe else {
                return AgentApplyResult(accepted: false, previous: previous, state: pane.state)
            }
            pane.ageOnProbe = false
            pane.waitingLoops = []
            if pane.state.kind != nil { pane.state.status = .idle }
            panes[id] = pane
            return AgentApplyResult(accepted: true, previous: previous, state: pane.state)
        }
        guard command.isEmpty else {
            pane.misses = 0
            pane.ageOnProbe = false   // the agent (or its tool) is still there
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
            pane.waitingLoops = []
            pane.ageOnProbe = false
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
