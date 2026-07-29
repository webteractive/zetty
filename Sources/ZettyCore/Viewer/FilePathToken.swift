import Foundation

/// A file reference lifted out of a line of terminal output. `line`/`column`
/// are 1-based, as the tools that print them emit them.
public struct PathToken: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

/// A `PathToken` plus the inclusive cell range it occupied, so the hover
/// underline can span exactly the text that was matched.
public struct PathMatch: Equatable, Sendable {
    public let token: PathToken
    public let startColumn: Int
    public let endColumn: Int

    public init(token: PathToken, startColumn: Int, endColumn: Int) {
        self.token = token
        self.startColumn = startColumn
        self.endColumn = endColumn
    }
}

/// Extraction of `path[:line[:col]]` references from terminal output. Pure and
/// deliberately permissive: whether the path *exists* is decided by the caller
/// (see `PathResolution`), which is what lets extensionless names like
/// `Makefile` work without a filename heuristic here.
public enum FilePathToken {

    /// Characters that terminate a path token in terminal output.
    private static let boundaries: Set<Character> = [
        " ", "\t", "\"", "'", "`", "(", ")", "[", "]", "<", ">", "{", "}", ",", "=",
    ]

    /// Trailing characters tools append after a reference, never part of it.
    private static let trailingJunk: Set<Character> = [":", ",", ".", ";", ")", "]", "'", "\""]

    /// The path reference straddling `column` (a 0-based cell index) in `line`.
    public static func match(in line: String, column: Int) -> PathMatch? {
        let chars = Array(line)
        guard column >= 0, column < chars.count else { return nil }
        guard !boundaries.contains(chars[column]) else { return nil }

        var start = column
        while start > 0, !boundaries.contains(chars[start - 1]) { start -= 1 }
        var end = column
        while end + 1 < chars.count, !boundaries.contains(chars[end + 1]) { end += 1 }

        var raw = String(chars[start...end])
        while let last = raw.last, trailingJunk.contains(last) {
            raw.removeLast()
            end -= 1
        }
        guard let token = parse(raw), end >= start else { return nil }
        return PathMatch(token: token, startColumn: start, endColumn: end)
    }

    /// Splits a raw token into its path and up to two trailing `:line:col`
    /// segments. Returns nil for text that can't be a path at all.
    public static func parse(_ raw: String) -> PathToken? {
        var segments = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // Peel at most two trailing all-digit segments — more than that is path.
        var position: [Int] = []
        while position.count < 2, segments.count > 1, let n = positiveInt(segments[segments.count - 1]) {
            position.append(n)
            segments.removeLast()
        }
        let path = segments.joined(separator: ":")
        guard isPlausiblePath(path) else { return nil }

        // `position` is peeled right-to-left: [col, line] or [line].
        let line = position.last
        let column = position.count == 2 ? position[0] : nil
        return PathToken(path: path, line: line, column: column)
    }

    /// Rejects only what cannot be a path: empty, or nothing but digits (a bare
    /// line number left over from a partial match).
    private static func isPlausiblePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return path.contains { !$0.isNumber }
    }

    private static func positiveInt(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let n = Int(text), n > 0 else { return nil }
        return n
    }
}
