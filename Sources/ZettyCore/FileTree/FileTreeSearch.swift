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
    ///
    /// Delegates to the shared `FuzzyMatch`, which the command palette uses
    /// too — two fuzzy matchers would drift, and this one's behaviour is the
    /// one users already have a feel for.
    static func score(query: String, candidate: String) -> Int? {
        FuzzyMatch.score(query: query, candidate: candidate)
    }
}
