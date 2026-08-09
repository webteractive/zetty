import Foundation

/// Fuzzy filename ranking for the file tree's filter field.
///
/// Subsequence matching with positional bonuses, in the spirit of `fzf`: typing
/// `tvc` should find `TerminalViewController.swift`. Scores are only ever
/// compared against each other, never shown, so their absolute magnitude is
/// arbitrary — the ordering is the contract.
public enum FileTreeSearch {

    public struct Match: Sendable, Equatable {
        public let path: String
        public let score: Int

        public init(path: String, score: Int) {
            self.path = path
            self.score = score
        }
    }

    /// Ranks `paths` against `query`, best first.
    ///
    /// Matching runs on each path's portion *below* `root`, so a root directory
    /// named `core` can't make every file in it match "core". Results carry the
    /// original absolute paths.
    public static func rank(
        query: String,
        paths: [String],
        root: String,
        limit: Int = 500
    ) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let prefix = root.hasSuffix("/") ? root : root + "/"
        var matches: [Match] = []
        for path in paths {
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            guard let score = score(query: trimmed, candidate: relative) else { continue }
            matches.append(Match(path: path, score: score))
        }

        matches.sort { a, b in
            a.score == b.score ? a.path < b.path : a.score > b.score
        }
        return Array(matches.prefix(limit))
    }

    /// Score for one candidate, or nil when `query` is not a subsequence of it.
    static func score(query: String, candidate: String) -> Int? {
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
            } else if "_-. ".contains(haystack[index - 1]) {
                total += 4                                           // word boundary
            }
            previousMatch = index
            next += 1
        }
        guard next == needle.count else { return nil }

        // A match wholly inside the basename beats one smeared across directories.
        let basenameStart = haystack.lastIndex(of: "/").map { $0 + 1 } ?? 0
        if firstMatch >= basenameStart { total += 20 }

        // Mild preference for shorter paths, so ties resolve sensibly.
        return total - haystack.count / 8
    }
}
