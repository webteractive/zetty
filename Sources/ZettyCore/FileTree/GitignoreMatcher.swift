import Foundation

/// Matches paths against one `.gitignore` file's patterns.
///
/// Implements the subset of gitignore semantics a file tree needs: globs
/// (`*`, `?`, `**`, character classes), anchoring (a slash anywhere but the end
/// pins the pattern to this file's own directory), directory-only patterns
/// (`build/`), negation (`!keep.log`), and last-match-wins ordering.
///
/// **Not** implemented, deliberately: ancestor propagation. Git ignores a file
/// whose parent directory is ignored; the file tree gets that for free because
/// it never descends into a directory it has already hidden. Also out of scope:
/// the global gitignore and `.git/info/exclude`.
public struct GitignoreMatcher: Sendable {

    struct Pattern: Sendable {
        /// Anchored regex (`^…$`) matched against the path relative to `base`.
        let regex: String
        let isNegated: Bool
        let directoryOnly: Bool
    }

    /// Absolute directory the `.gitignore` lives in, without a trailing slash.
    public let base: String
    let patterns: [Pattern]

    public init(base: String, contents: String) {
        self.base = base.hasSuffix("/") && base.count > 1 ? String(base.dropLast()) : base
        // Normalize CRLF first: Swift treats "\r\n" as a SINGLE Character, so
        // splitting on "\n" would never split a CRLF file — the whole thing
        // would collapse into one nonsense pattern and silently match nothing.
        patterns = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { Self.parseLine(String($0)) }
    }

    /// `true` = ignored, `false` = explicitly un-ignored by a `!` rule,
    /// `nil` = this file has no opinion (including any path outside `base`).
    public func decision(path: String, isDirectory: Bool) -> Bool? {
        guard let relative = Self.relativePath(of: path, under: base) else { return nil }
        var verdict: Bool?
        // Last matching pattern wins, so no early exit.
        for pattern in patterns {
            if pattern.directoryOnly, !isDirectory { continue }
            guard relative.range(of: pattern.regex, options: .regularExpression) != nil else { continue }
            verdict = !pattern.isNegated
        }
        return verdict
    }

    static func relativePath(of path: String, under base: String) -> String? {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    // MARK: Parsing

    static func parseLine(_ raw: String) -> Pattern? {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        // Trailing whitespace is not significant unless escaped; we don't
        // support the escaped form, matching what real .gitignore files do.
        while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

        var isNegated = false
        if line.hasPrefix("!") {
            isNegated = true
            line.removeFirst()
        } else if line.hasPrefix("\\#") || line.hasPrefix("\\!") {
            line.removeFirst()      // an escaped leading # or ! is a literal
        }
        guard !line.isEmpty else { return nil }

        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line.removeLast()
        }
        guard !line.isEmpty else { return nil }

        // A slash anywhere (now that the trailing one is gone) anchors the
        // pattern to this .gitignore's directory.
        let isAnchored = line.contains("/")
        if line.hasPrefix("/") { line.removeFirst() }
        guard !line.isEmpty else { return nil }

        guard let body = translate(glob: line) else { return nil }
        return Pattern(
            regex: isAnchored ? "^\(body)$" : "^(?:.*/)?\(body)$",
            isNegated: isNegated,
            directoryOnly: directoryOnly
        )
    }

    /// Translates a gitignore glob to a regex body, or nil when the glob is
    /// malformed (an unclosed character class) — a bad line is skipped, the way
    /// git tolerates junk rather than failing the whole file.
    static func translate(glob: String) -> String? {
        let chars = Array(glob)
        var out = ""
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "*":
                let isDouble = i + 1 < chars.count && chars[i + 1] == "*"
                if isDouble {
                    if i + 2 < chars.count, chars[i + 2] == "/" {
                        out += "(?:.*/)?"       // `**/` — zero or more directories
                        i += 3
                    } else {
                        out += ".*"             // `**` — crosses separators
                        i += 2
                    }
                } else {
                    out += "[^/]*"              // `*` — stays within one segment
                    i += 1
                }
            case "?":
                out += "[^/]"
                i += 1
            case "[":
                guard let close = chars[(i + 1)...].firstIndex(of: "]") else { return nil }
                var body = Array(chars[(i + 1)..<close])
                if body.first == "!" { body[0] = "^" }   // gitignore uses ! for negation
                out += "[" + String(body) + "]"
                i = close + 1
            case "\\":
                guard i + 1 < chars.count else { return nil }
                out += NSRegularExpression.escapedPattern(for: String(chars[i + 1]))
                i += 2
            default:
                out += NSRegularExpression.escapedPattern(for: String(chars[i]))
                i += 1
            }
        }
        return out
    }
}

// MARK: - Layering

/// The `.gitignore` files in scope for a tree, layered by directory depth.
///
/// A deeper file's opinion overrides a shallower one's, which is how a nested
/// `.gitignore` re-includes something the repo root excluded.
public struct GitignoreStack: Sendable {
    let matchers: [GitignoreMatcher]

    /// `matchers` may arrive in any order; they are sorted shallowest-first so
    /// the deepest opinion is applied last.
    public init(matchers: [GitignoreMatcher]) {
        self.matchers = matchers.sorted { $0.base.count < $1.base.count }
    }

    public func isIgnored(path: String, isDirectory: Bool) -> Bool {
        var verdict = false
        for matcher in matchers {
            if let decision = matcher.decision(path: path, isDirectory: isDirectory) {
                verdict = decision
            }
        }
        return verdict
    }
}
