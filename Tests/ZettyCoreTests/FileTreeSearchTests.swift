import Foundation
import Testing
@testable import ZettyCore

// MARK: - Matching

@Test func nonSubsequenceDoesNotMatch() {
    #expect(FileTreeSearch.score(query: "zzz", candidate: "abc.txt") == nil)
}

@Test func matchingIsCaseInsensitive() {
    #expect(FileTreeSearch.score(query: "TVC", candidate: "TerminalViewController.swift") != nil)
}

@Test func subsequenceMatchesAcrossSeparators() {
    #expect(FileTreeSearch.score(query: "atb", candidate: "a/t/b.txt") != nil)
}

// MARK: - Ranking properties (equal-length candidates isolate the property)

@Test func consecutiveMatchOutranksScatteredMatch() {
    let consecutive = FileTreeSearch.score(query: "abc", candidate: "abcxxx.txt")
    let scattered = FileTreeSearch.score(query: "abc", candidate: "axbxcx.txt")
    #expect(consecutive != nil && scattered != nil)
    #expect(consecutive! > scattered!)
}

@Test func matchInsideBasenameOutranksMatchInDirectories() {
    let inBasename = FileTreeSearch.score(query: "core", candidate: "aa/bb/core.swift")
    let inDirectory = FileTreeSearch.score(query: "core", candidate: "core/bb/aa.swift")
    #expect(inBasename != nil && inDirectory != nil)
    #expect(inBasename! > inDirectory!)
}

@Test func shorterPathWinsWhenEverythingElseIsEqual() {
    let short = FileTreeSearch.score(query: "abc", candidate: "abc.txt")
    let long = FileTreeSearch.score(query: "abc", candidate: "abc.txt/aaaaaaaaaaaaaaaa")
    #expect(short != nil && long != nil)
    #expect(short! > long!)
}

// MARK: - rank()

@Test func emptyQueryReturnsNoMatches() {
    #expect(FileTreeSearch.rank(query: "   ", paths: ["/r/a.txt"], root: "/r").isEmpty)
}

@Test func rankStripsTheRootPrefixSoTheRootNameNeverMatches() {
    // Root directory named "core" must not make every file match "core".
    let matches = FileTreeSearch.rank(query: "core", paths: ["/Users/x/core/main.swift"],
                                      root: "/Users/x/core")
    #expect(matches.isEmpty)
}

@Test func rankKeepsAbsolutePathsInItsResults() {
    let matches = FileTreeSearch.rank(query: "main", paths: ["/Users/x/core/main.swift"],
                                      root: "/Users/x/core")
    #expect(matches.map(\.path) == ["/Users/x/core/main.swift"])
}

@Test func equalScoresBreakTiesByPathAscending() {
    let matches = FileTreeSearch.rank(query: "txt", paths: ["/r/b.txt", "/r/a.txt"], root: "/r")
    #expect(matches.map(\.path) == ["/r/a.txt", "/r/b.txt"])
}

@Test func rankRespectsTheLimit() {
    let paths = (1...50).map { "/r/file\($0).txt" }
    #expect(FileTreeSearch.rank(query: "file", paths: paths, root: "/r", limit: 10).count == 10)
}

@Test func rankHandlesARootWithATrailingSlash() {
    let matches = FileTreeSearch.rank(query: "main", paths: ["/r/main.swift"], root: "/r/")
    #expect(matches.count == 1)
}
