import Testing
@testable import ZettyCore

@Test func agentEventParsesWellFormedLine() {
    let e = AgentEvent.parse(line: #"{"cwd":"/Users/me/proj","agent":"claude","event":"needsAttention"}"#)
    #expect(e == AgentEvent(cwd: "/Users/me/proj", agent: .claude, event: .needsAttention))
    #expect(e?.hookEvent == .needsAttention)
}

@Test func agentEventMapsFriendlyEventAliases() {
    #expect(AgentEvent.parse(line: #"{"cwd":"/x","agent":"claude","event":"Notification"}"#)?.event == .needsAttention)
    #expect(AgentEvent.parse(line: #"{"cwd":"/x","agent":"claude","event":"Stop"}"#)?.event == .idle)
    #expect(AgentEvent.parse(line: #"{"cwd":"/x","agent":"claude","event":"PostToolUse"}"#)?.event == .running)
    #expect(AgentEvent.parse(line: #"{"cwd":"/x","agent":"claude","event":"SessionEnd"}"#)?.event == .ended)
}

@Test func agentEventEndedHasNoHookEvent() {
    #expect(AgentEvent.parse(line: #"{"cwd":"/x","agent":"codex","event":"ended"}"#)?.hookEvent == nil)
}

@Test func agentEventResolvesAgentByBinaryName() {
    // "OpenCode" isn't an AgentKind raw value but resolves via the registry.
    #expect(AgentEvent.parse(line: #"{"cwd":"/x","agent":"OpenCode","event":"running"}"#)?.agent == .opencode)
}

@Test func agentEventRejectsMalformedOrUnknown() {
    #expect(AgentEvent.parse(line: "not json") == nil)
    #expect(AgentEvent.parse(line: #"{"cwd":"/x","agent":"vim","event":"running"}"#) == nil)   // unknown agent
    #expect(AgentEvent.parse(line: #"{"cwd":"/x","agent":"claude","event":"nope"}"#) == nil)    // unknown event
    #expect(AgentEvent.parse(line: #"{"agent":"claude","event":"running"}"#) == nil)            // missing cwd
}
