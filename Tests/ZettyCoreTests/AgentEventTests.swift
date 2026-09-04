import Foundation
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

// MARK: - Surface + session fields (restart recovery)

@Test func agentEventLegacyThreeFieldLineHasNoSurfaceOrSession() {
    let e = AgentEvent.parse(line: #"{"cwd":"/x","agent":"claude","event":"idle"}"#)
    #expect(e?.surface == nil)
    #expect(e?.session == nil)
}

@Test func agentEventParsesSurfaceAndSession() {
    let e = AgentEvent.parse(line: #"{"cwd":"/x","agent":"claude","event":"running","surface":"5F0C2A1E-0000-4000-8000-000000000001","session":"8d1e2b6c-aaaa-4bbb-8ccc-000000000002"}"#)
    #expect(e?.surface == UUID(uuidString: "5F0C2A1E-0000-4000-8000-000000000001"))
    #expect(e?.session == "8d1e2b6c-aaaa-4bbb-8ccc-000000000002")
}

@Test func agentEventDropsMalformedSurfaceButKeepsLine() {
    let e = AgentEvent.parse(line: #"{"cwd":"/x","agent":"claude","event":"running","surface":"not-a-uuid"}"#)
    #expect(e != nil)
    #expect(e?.surface == nil)
}

@Test func agentEventDropsSessionWithForbiddenCharacters() {
    // Read back from a file and later typed into a shell: must be inert by construction.
    let e = AgentEvent.parse(line: #"{"cwd":"/x","agent":"codex","event":"idle","session":"abc'; rm -rf ~"}"#)
    #expect(e != nil)
    #expect(e?.session == nil)
    #expect(AgentEvent.isValidSessionID("019a-b.c_D") == true)
    #expect(AgentEvent.isValidSessionID("") == false)
    #expect(AgentEvent.isValidSessionID(String(repeating: "a", count: 129)) == false)
}
