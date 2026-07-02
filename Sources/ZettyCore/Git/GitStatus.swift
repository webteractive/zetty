import Foundation

/// A snapshot of a directory's git state for display in the status bar.
///
/// The struct is pure data; the parsing helpers turn raw `git` output into
/// values (and are unit-tested). Spawning `git` itself lives in the app layer.
public struct GitStatus: Equatable, Sendable {
    public var branch: String   // branch name, short SHA when detached, or "" when not a repo
    public var ahead: Int       // commits ahead of upstream
    public var behind: Int      // commits behind upstream
    public var changes: Int     // dirty entries (staged + unstaged + untracked)
    public var isRepo: Bool

    public init(branch: String, ahead: Int, behind: Int, changes: Int, isRepo: Bool) {
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
        self.isRepo = isRepo
    }

    /// Not a git repository (or git unavailable).
    public static let none = GitStatus(branch: "", ahead: 0, behind: 0, changes: 0, isRepo: false)

    // MARK: - Parsers

    /// Trims `git rev-parse --abbrev-ref HEAD` output to a branch name.
    /// A detached HEAD yields "HEAD" (the caller substitutes a short SHA).
    public static func cleanBranch(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses `git rev-list --left-right --count @{upstream}...HEAD`, whose output
    /// is "<behind>\t<ahead>" (left = upstream-only commits, right = HEAD-only).
    /// Returns zeros for missing upstream / malformed output.
    public static func parseAheadBehind(_ output: String) -> (ahead: Int, behind: Int) {
        let parts = output
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .compactMap { Int($0) }
        guard parts.count == 2 else { return (0, 0) }
        return (ahead: parts[1], behind: parts[0])
    }

    /// Counts non-empty lines of `git status --porcelain` output (one per dirty entry).
    public static func parseChangeCount(_ porcelain: String) -> Int {
        porcelain
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }
}
