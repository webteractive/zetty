import Testing
import Foundation
@testable import ZettyCore

private let claude = AgentRegistry.all.first { $0.kind == .claude }!   // honorsHooks: true, idleAfter: 5
private let codex  = AgentRegistry.all.first { $0.kind == .codex }!    // honorsHooks: false, idleAfter: 5

private func reduce(
    prev: AgentState = .init(),
    descriptor: AgentDescriptor?,
    lastOutputAt: TimeInterval? = nil,
    hook: HookEvent? = nil,
    now: TimeInterval
) -> AgentState {
    AgentStateMachine.reduce(
        previous: prev,
        observation: AgentObservation(descriptor: descriptor, lastOutputAt: lastOutputAt, hookEvent: hook, now: now)
    )
}

@Test func noDescriptorClearsState() {
    let prev = AgentState(kind: .claude, status: .running)
    let s = reduce(prev: prev, descriptor: nil, now: 100)
    #expect(s == AgentState(kind: nil, status: nil))
}

@Test func recentOutputIsRunning() {
    let s = reduce(descriptor: codex, lastOutputAt: 99.5, now: 100)  // 0.5s ago <= 0.75 window
    #expect(s == AgentState(kind: .codex, status: .running))
}

@Test func silenceBeyondIdleAfterIsIdle() {
    let s = reduce(descriptor: codex, lastOutputAt: 90, now: 100)    // 10s ago >= idleAfter 5
    #expect(s == AgentState(kind: .codex, status: .idle))
}

@Test func hookEventWinsOverActivity() {
    let s = reduce(descriptor: claude, lastOutputAt: 99.9, hook: .needsAttention, now: 100)
    #expect(s == AgentState(kind: .claude, status: .needsAttention))
}

@Test func nonHookAgentNeverGetsAttentionFromHeuristics() {
    // codex.honorsHooks == false; prior needsAttention must not stick without a hook.
    let prev = AgentState(kind: .codex, status: .needsAttention)
    let s = reduce(prev: prev, descriptor: codex, lastOutputAt: 90, now: 100)
    #expect(s.status == .idle)
}

@Test func attentionIsStickyForHookAgentUntilFreshOutput() {
    let prev = AgentState(kind: .claude, status: .needsAttention)
    // No fresh output (last output 10s ago): stays needsAttention.
    let held = reduce(prev: prev, descriptor: claude, lastOutputAt: 90, now: 100)
    #expect(held.status == .needsAttention)
    // Fresh output within window clears stickiness → running.
    let cleared = reduce(prev: prev, descriptor: claude, lastOutputAt: 99.9, now: 100)
    #expect(cleared.status == .running)
}
