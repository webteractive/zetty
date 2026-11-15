import Testing
@testable import ZettyCore

@Test func newestSourceWins() {
    #expect(CurrentDirectory.choose(cwdFile: StampedPath(path: "/a", at: 10), osc7: StampedPath(path: "/b", at: 12),
                                    agent: nil, persisted: "/p", spawn: "/s") == "/b")
    #expect(CurrentDirectory.choose(cwdFile: StampedPath(path: "/a", at: 14), osc7: StampedPath(path: "/b", at: 12),
                                    agent: nil, persisted: "/p", spawn: "/s") == "/a")
}

@Test func agentFolderWinsWhenNewest() {
    #expect(CurrentDirectory.choose(cwdFile: StampedPath(path: "/repo", at: 10), osc7: nil,
                                    agent: StampedPath(path: "/repo/.worktrees/x", at: 20),
                                    persisted: nil, spawn: "/s") == "/repo/.worktrees/x")
}

@Test func persistedBeatsSpawnWhenNothingReported() {
    #expect(CurrentDirectory.choose(cwdFile: nil, osc7: nil, agent: nil, persisted: "/tmp", spawn: "/s") == "/tmp")
}

@Test func spawnIsLastResort() {
    #expect(CurrentDirectory.choose(cwdFile: nil, osc7: nil, agent: nil, persisted: nil, spawn: "/s") == "/s")
    #expect(CurrentDirectory.choose(cwdFile: nil, osc7: nil, agent: nil, persisted: "", spawn: "/s") == "/s")
}

@Test func emptyReportedPathIsIgnored() {
    #expect(CurrentDirectory.choose(cwdFile: nil, osc7: nil, agent: StampedPath(path: "", at: 20),
                                    persisted: "/p", spawn: "/s") == "/p")
}
