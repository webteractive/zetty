import Foundation

/// Ranks command-palette labels against what the user typed.
///
/// Fuzzy rather than substring, so `go zetty` finds `Go to Project: zetty` —
/// a plain `contains` needs the query to appear verbatim, which means knowing
/// a command's exact wording before you can search for it.
public enum CommandSearch {

    /// Indices into `labels`, best match first.
    ///
    /// An empty query returns every index in the original order: before
    /// anything is typed the palette is a menu, and its authored grouping
    /// carries more information than a score would.
    ///
    /// Whitespace splits the query into terms, and **every term must match**.
    /// AND rather than OR, because a second word that widened the results
    /// would read as the filter breaking; it also lets the terms be typed in
    /// any order, so `zetty go` works as well as `go zetty`.
    public static func rank(query: String, labels: [String]) -> [Int] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return Array(labels.indices) }

        var scored: [(index: Int, score: Int)] = []
        for (index, label) in labels.enumerated() {
            var total = 0
            var matchedEveryTerm = true
            for term in terms {
                guard let score = FuzzyMatch.score(query: term, candidate: label) else {
                    matchedEveryTerm = false
                    break
                }
                total += score
            }
            if matchedEveryTerm { scored.append((index, total)) }
        }

        // Ties break on the original index, never on the label: the selection
        // sits at row 0, so an unstable order would change what Enter runs
        // between identical keystrokes.
        scored.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        return scored.map(\.index)
    }
}
