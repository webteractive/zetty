import Foundation

/// Subsequence matching with positional bonuses, in the spirit of `fzf`:
/// typing `tvc` finds `TerminalViewController.swift`, and `go zetty` finds
/// `Go to Project: zetty`.
///
/// Shared by the file tree's filter and the command palette's. Scores are only
/// ever compared against each other, never shown, so their absolute magnitude
/// is arbitrary — the ordering is the contract.
public enum FuzzyMatch {

    /// Characters after which a match counts as starting a word. `/` earns the
    /// larger segment bonus separately, in `score`.
    private static let wordBoundaries: Set<Character> = ["_", "-", ".", " ", ":", "/"]

    /// Score for one candidate, or nil when `query` is not a subsequence of it.
    ///
    /// An empty query scores 0 rather than failing — callers decide whether an
    /// empty query means "everything" or "nothing", and they disagree.
    public static func score(query: String, candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        let haystack = Array(candidate.lowercased())
        guard !needle.isEmpty else { return 0 }

        var total = 0
        var next = 0
        var previousMatch = -2
        var firstMatch = -1

        for (index, character) in haystack.enumerated() {
            guard next < needle.count, character == needle[next] else { continue }
            if firstMatch < 0 { firstMatch = index }
            if index == previousMatch + 1 { total += 8 }             // run of matches
            if index == 0 || haystack[index - 1] == "/" {
                total += 12                                          // path segment start
            } else if wordBoundaries.contains(haystack[index - 1]) {
                total += 4                                           // word boundary
            }
            previousMatch = index
            next += 1
        }
        guard next == needle.count else { return nil }

        // A match wholly inside the last segment beats one smeared across the
        // ones before it — the basename of a path, the name at the end of a
        // command label.
        let lastSegmentStart = haystack.lastIndex(of: "/").map { $0 + 1 } ?? 0
        if firstMatch >= lastSegmentStart { total += 20 }

        // Mild preference for shorter candidates, so ties resolve sensibly.
        return total - haystack.count / 8
    }
}
