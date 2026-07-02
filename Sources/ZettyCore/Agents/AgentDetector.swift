import Foundation

/// A probe that never resolves a command — used when detection is driven purely
/// by harness hooks (the current mechanism) rather than foreground-process scans.
public struct NullForegroundProcessProbe: ForegroundProcessProbe {
    public init() {}
    public func foregroundCommand(forPTY fd: Int32) -> String? { nil }
}

public final class AgentDetector {
    private let probe: ForegroundProcessProbe
    private var states: [UUID: AgentState] = [:]

    public init(probe: ForegroundProcessProbe = NullForegroundProcessProbe()) {
        self.probe = probe
    }

    public func state(for session: UUID) -> AgentState {
        states[session] ?? AgentState()
    }

    /// Applies a harness-hook `AgentEvent` to `session` and returns the new state.
    /// `.ended` clears presence; other events set the reported status
    /// authoritatively (hooks win over heuristics in the reducer).
    @discardableResult
    public func apply(event: AgentEvent, session: UUID, now: TimeInterval) -> AgentState {
        let descriptor: AgentDescriptor? = event.event == .ended
            ? nil
            : AgentRegistry.all.first { $0.kind == event.agent }
        let observation = AgentObservation(
            descriptor: descriptor,
            lastOutputAt: nil,
            hookEvent: event.hookEvent,
            now: now
        )
        let next = AgentStateMachine.reduce(previous: state(for: session), observation: observation)
        states[session] = next
        return next
    }

    /// Clears a session's state (e.g. when its surface closes).
    public func clear(session: UUID) {
        states[session] = nil
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
        states[session] = next
        return next
    }
}
