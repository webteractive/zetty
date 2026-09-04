import Testing
@testable import ZettyCore

@Test func replayKeepsLatestEventPerCwdAndAgent() {
    let log = """
    {"cwd": "/a", "agent": "claude", "event": "running"}
    {"cwd": "/a", "agent": "claude", "event": "idle"}
    {"cwd": "/b", "agent": "codex", "event": "running"}
    """
    let events = AgentEventReplay.liveEvents(fromJSONL: log)
    #expect(events == [
        AgentEvent(cwd: "/a", agent: .claude, event: .idle),
        AgentEvent(cwd: "/b", agent: .codex, event: .running),
    ])
}

@Test func replayDropsAgentsWhoseLastEventWasEnded() {
    let log = """
    {"cwd": "/a", "agent": "claude", "event": "running"}
    {"cwd": "/a", "agent": "claude", "event": "ended"}
    {"cwd": "/b", "agent": "claude", "event": "running"}
    """
    let events = AgentEventReplay.liveEvents(fromJSONL: log)
    #expect(events == [AgentEvent(cwd: "/b", agent: .claude, event: .running)])
}

@Test func replayToleratesMalformedAndBlankLines() {
    let log = """
    not json at all

    {"cwd": "/a", "agent": "claude"}
    {"cwd": "/a", "agent": "claude", "event": "running"}
    """
    let events = AgentEventReplay.liveEvents(fromJSONL: log)
    #expect(events == [AgentEvent(cwd: "/a", agent: .claude, event: .running)])
}

@Test func replayOfEmptyLogIsEmpty() {
    #expect(AgentEventReplay.liveEvents(fromJSONL: "").isEmpty)
}

@Test func sameAgentInDifferentCwdsTrackedIndependently() {
    let log = """
    {"cwd": "/a", "agent": "claude", "event": "running"}
    {"cwd": "/b", "agent": "claude", "event": "ended"}
    """
    let events = AgentEventReplay.liveEvents(fromJSONL: log)
    #expect(events == [AgentEvent(cwd: "/a", agent: .claude, event: .running)])
}

@Test func replayKeepsTwoPanesInOneDirectoryApartWhenSurfacesAreKnown() {
    let a = "5F0C2A1E-0000-4000-8000-000000000001"
    let b = "5F0C2A1E-0000-4000-8000-000000000002"
    let log = """
    {"cwd": "/a", "agent": "claude", "event": "running", "surface": "\(a)", "session": "s-a"}
    {"cwd": "/a", "agent": "claude", "event": "idle", "surface": "\(b)", "session": "s-b"}
    """
    let events = AgentEventReplay.liveEvents(fromJSONL: log)
    #expect(events.count == 2)
    #expect(events.map(\.session) == ["s-a", "s-b"])
}
