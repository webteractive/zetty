import Foundation
import Testing
@testable import ZettyCore

private let sA = UUID(uuidString: "5F0C2A1E-0000-4000-8000-00000000000A")!
private let sB = UUID(uuidString: "5F0C2A1E-0000-4000-8000-00000000000B")!
private let sC = UUID(uuidString: "5F0C2A1E-0000-4000-8000-00000000000C")!
private let sD = UUID(uuidString: "5F0C2A1E-0000-4000-8000-00000000000D")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test func makeTalliesSnapshotsAndSessionsAndDropsSurfacesWithNeither() {
    let states: [UUID: AgentState] = [
        sA: AgentState(kind: .claude, status: .running, session: AgentSession(id: "cl-1", cwd: "/p")),
        sC: AgentState(kind: .codex, status: .idle, session: AgentSession(id: "cx-1", cwd: "/q")),
        sD: AgentState(kind: .claude, status: .idle),                 // present but no id known
    ]
    let m = RestartRecovery.Manifest.make(
        surfaces: [sA, sB, sC, sD],
        snapshots: [sA: "/snap/a.vt", sB: "/snap/b.vt"],
        agentStates: states,
        now: t0)
    #expect(m.version == RestartRecovery.currentVersion)
    #expect(m.writtenAt == t0)
    #expect(m.entries == [
        .init(surface: sA, snapshot: "/snap/a.vt", agent: .claude, agentSession: "cl-1", agentCwd: "/p"),
        .init(surface: sB, snapshot: "/snap/b.vt", agent: nil, agentSession: nil, agentCwd: nil),
        .init(surface: sC, snapshot: nil, agent: .codex, agentSession: "cx-1", agentCwd: "/q"),
    ])
}

@Test func manifestRoundTripsAndTolerantlyDecodesSparseEntries() throws {
    let m = RestartRecovery.Manifest(version: 1, writtenAt: t0, entries: [
        .init(surface: sA, snapshot: "/snap/a.vt", agent: .claude, agentSession: "cl-1", agentCwd: "/p"),
    ])
    let data = try #require(m.encoded())
    #expect(RestartRecovery.Manifest.decode(data) == m)

    let sparse = """
    {"version":1,"writtenAt":"2027-01-15T08:00:00Z","entries":[{"surface":"\(sB.uuidString)"},
     {"surface":"\(sC.uuidString)","agent":"codex","agentSession":"cx","agentCwd":"/q","futureField":true}]}
    """.data(using: .utf8)!
    let decoded = try #require(RestartRecovery.Manifest.decode(sparse))
    #expect(decoded.entries.count == 2)
    #expect(decoded.entries[0].snapshot == nil)
    #expect(decoded.entries[1].agent == .codex)
}

@Test func manifestWithUnknownVersionOrGarbageDecodesToNil() {
    #expect(RestartRecovery.Manifest.decode(#"{"version":99,"writtenAt":"2027-01-15T08:00:00Z","entries":[]}"#.data(using: .utf8)!) == nil)
    #expect(RestartRecovery.Manifest.decode("not json".data(using: .utf8)!) == nil)
}

@Test func entriesApplyingToDropsUnknownSurfacesAndReportsTheirSnapshots() {
    let m = RestartRecovery.Manifest(version: 1, writtenAt: t0, entries: [
        .init(surface: sA, snapshot: "/snap/a.vt", agent: nil, agentSession: nil, agentCwd: nil),
        .init(surface: sB, snapshot: "/snap/b.vt", agent: .claude, agentSession: "x", agentCwd: "/p"),
        .init(surface: sC, snapshot: nil, agent: .claude, agentSession: "y", agentCwd: "/p"),
    ])
    let result = m.entries(applyingTo: [sA, sC])
    #expect(result.kept.map(\.surface) == [sA, sC])
    #expect(result.droppedSnapshotPaths == ["/snap/b.vt"])
}

@Test func resumeCommandForClaudeAndCodexWithQuotedCwd() {
    #expect(RestartRecovery.resumeCommand(agent: .claude, sessionID: "8d1e-2b6c", cwd: "/Users/g/AI/zetty")
            == "cd '/Users/g/AI/zetty' && claude --resume '8d1e-2b6c'")
    #expect(RestartRecovery.resumeCommand(agent: .codex, sessionID: "019a", cwd: "/Users/g/it's here")
            == #"cd '/Users/g/it'\''s here' && codex resume '019a'"#)
}

@Test func resumeCommandIsNilForAgentsWithoutAVerifiedGrammarOrABadID() {
    #expect(RestartRecovery.resumeCommand(agent: .hermes, sessionID: "abc", cwd: "/p") == nil)
    #expect(RestartRecovery.resumeCommand(agent: .gemini, sessionID: "abc", cwd: "/p") == nil)
    #expect(RestartRecovery.resumeCommand(agent: .claude, sessionID: "abc'; rm -rf ~", cwd: "/p") == nil)
}

@Test func snapshotFileNameFollowsTheSessionName() {
    #expect(RestartRecovery.snapshotFileName(for: sA) == SessionPersistence.sessionName(for: sA) + ".vt")
}
