import Testing
@testable import ZettyCore

@Test func gitParsesAheadBehindBehindThenAhead() {
    // `rev-list --left-right --count @{u}...HEAD` prints "<behind>\t<ahead>".
    let (ahead, behind) = GitStatus.parseAheadBehind("3\t2")
    #expect(ahead == 2)
    #expect(behind == 3)
}

@Test func gitAheadBehindHandlesMalformed() {
    #expect(GitStatus.parseAheadBehind("") == (0, 0))
    #expect(GitStatus.parseAheadBehind("garbage") == (0, 0))
    #expect(GitStatus.parseAheadBehind("1 2 3") == (0, 0))
}

@Test func gitCountsPorcelainLines() {
    let porcelain = " M file1.swift\n?? new.txt\nA  staged.md\n"
    #expect(GitStatus.parseChangeCount(porcelain) == 3)
}

@Test func gitCountsZeroForCleanTree() {
    #expect(GitStatus.parseChangeCount("") == 0)
    #expect(GitStatus.parseChangeCount("\n\n") == 0)
}

@Test func gitCleanBranchTrims() {
    #expect(GitStatus.cleanBranch("main\n") == "main")
    #expect(GitStatus.cleanBranch("  feature/x  ") == "feature/x")
}
