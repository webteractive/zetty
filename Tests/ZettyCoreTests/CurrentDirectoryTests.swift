import Foundation
import Testing
@testable import ZettyCore

@Test func newestSourceWins() {
    #expect(CurrentDirectory.choose(cwdFile: StampedPath(path: "/a", at: 10), agent: StampedPath(path: "/b", at: 12), persisted: "/p", spawn: "/s") == "/b")
    #expect(CurrentDirectory.choose(cwdFile: StampedPath(path: "/a", at: 14), agent: StampedPath(path: "/b", at: 12), persisted: "/p", spawn: "/s") == "/a")
}

@Test func agentFolderWinsWhenNewest() {
    #expect(CurrentDirectory.choose(cwdFile: StampedPath(path: "/repo", at: 10), agent: StampedPath(path: "/repo/.worktrees/x", at: 20),
                                    persisted: nil, spawn: "/s") == "/repo/.worktrees/x")
}

@Test func persistedBeatsSpawnWhenNothingReported() {
    #expect(CurrentDirectory.choose(cwdFile: nil, agent: nil, persisted: "/tmp", spawn: "/s") == "/tmp")
}

@Test func spawnIsLastResort() {
    #expect(CurrentDirectory.choose(cwdFile: nil, agent: nil, persisted: nil, spawn: "/s") == "/s")
    #expect(CurrentDirectory.choose(cwdFile: nil, agent: nil, persisted: "", spawn: "/s") == "/s")
}

@Test func emptyReportedPathIsIgnored() {
    #expect(CurrentDirectory.choose(cwdFile: nil, agent: StampedPath(path: "", at: 20),
                                    persisted: "/p", spawn: "/s") == "/p")
}

/// A worktree removed from another pane, or a folder deleted before a
/// relaunch: a split there started in libghostty's default folder instead
/// of the project (release review, 2026-11-20). A folder that has gone is
/// skipped for the next one that is still there.
@Test func aFolderThatHasGoneIsSkippedForTheNextOne() {
    let gone: Set<String> = ["/repo/.worktrees/feat", "/old"]
    let exists = { (path: String) in !gone.contains(path) }
    #expect(CurrentDirectory.choose(
        cwdFile: StampedPath(path: "/repo/.worktrees/feat", at: 20), agent: StampedPath(path: "/repo/sub", at: 10),
        persisted: "/repo", spawn: "/home", exists: exists) == "/repo/sub")
    #expect(CurrentDirectory.choose(
        cwdFile: StampedPath(path: "/repo/.worktrees/feat", at: 20), agent: nil,
        persisted: "/old", spawn: "/home", exists: exists) == "/home")
}

/// A pane with no cwd file (bash, fish: Zetty's integration is zsh's) goes
/// by its shell's own working folder, read from the kernel, which no output
/// can fake (security review, 2026-11-20).
@Test func theShellsOwnFolderSpeaksWhenThereIsNoCwdFile() {
    #expect(CurrentDirectory.choose(
        cwdFile: nil, process: StampedPath(path: "/repo", at: 10),
        agent: nil,
        persisted: nil, spawn: "/home") == "/repo")
    // The cwd file, when the shell writes one, still speaks for it.
    #expect(CurrentDirectory.choose(
        cwdFile: StampedPath(path: "/repo/sub", at: 30), process: StampedPath(path: "/repo", at: 10),
        agent: nil, persisted: nil, spawn: "/home") == "/repo/sub")
}

@Test func aProcessesWorkingFolderIsReadFromTheKernel() {
    let own = ProcessDirectory.current(of: getpid())
    #expect(own.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
    #expect(ProcessDirectory.current(of: 0) == nil)
}
