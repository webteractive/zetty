import Testing
import Foundation
@testable import ZettyCore

private struct MockProbe: ForegroundProcessProbe {
    let command: String?
    func foregroundCommand(forPTY fd: Int32) -> String? { command }
}

private let s1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

@Test func detectorReportsPresenceFromProbe() {
    let detector = AgentDetector(probe: MockProbe(command: "/usr/bin/claude"))
    let state = detector.update(session: s1, ptyFD: 3, lastOutputAt: 99.9, hookEvent: nil, now: 100)
    #expect(state.kind == .claude)
    #expect(state.status == .running)
}

@Test func detectorClearsWhenNoAgentForeground() {
    let detector = AgentDetector(probe: MockProbe(command: "/bin/zsh"))
    let state = detector.update(session: s1, ptyFD: 3, lastOutputAt: 99.9, hookEvent: nil, now: 100)
    #expect(state.kind == nil)
    #expect(state.status == nil)
}

@Test func detectorAppliesHookEventBySession() {
    let detector = AgentDetector()
    let running = detector.apply(
        event: AgentEvent(cwd: "/x", agent: .claude, event: .needsAttention),
        session: s1, now: 100
    )
    #expect(running == AgentState(kind: .claude, status: .needsAttention))

    // `.ended` clears presence.
    let ended = detector.apply(
        event: AgentEvent(cwd: "/x", agent: .claude, event: .ended),
        session: s1, now: 101
    )
    #expect(ended == AgentState(kind: nil, status: nil))
}

@Test func detectorRemembersPerSessionStateForStickiness() {
    let detector = AgentDetector(probe: MockProbe(command: "claude"))
    _ = detector.update(session: s1, ptyFD: 3, lastOutputAt: 50, hookEvent: .needsAttention, now: 60)
    #expect(detector.state(for: s1).status == .needsAttention)
    // No fresh output → attention sticks (claude honorsHooks).
    let held = detector.update(session: s1, ptyFD: 3, lastOutputAt: 50, hookEvent: nil, now: 100)
    #expect(held.status == .needsAttention)
}
