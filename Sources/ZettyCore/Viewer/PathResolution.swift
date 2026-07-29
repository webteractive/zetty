import Foundation

/// Turns a `PathToken` into ordered absolute-path guesses. Pure: it returns
/// candidates and the caller stats them, which keeps filesystem access out of
/// `ZettyCore` and makes the ordering testable.
public enum PathResolution {

    public static func candidates(for token: PathToken,
                                  paneCwd: String?,
                                  projectRoot: String?) -> [String] {
        var out: [String] = []
        func add(_ path: String) {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard !normalized.isEmpty, !out.contains(normalized) else { return }
            out.append(normalized)
        }

        let raw = token.path
        if raw.hasPrefix("~") {
            add((raw as NSString).expandingTildeInPath)
            return out
        }
        if raw.hasPrefix("/") {
            add(raw)
            return out
        }

        // Relative: the pane's cwd first (that's where the output came from),
        // then the project root.
        let bases = [paneCwd, projectRoot].compactMap { $0 }
        for base in bases { add("\(base)/\(raw)") }
        // `git diff` prefixes name a repo-relative path; offer that only after
        // the literal reading, since a directory really called `a` can exist.
        if let stripped = strippingDiffPrefix(raw) {
            for base in bases { add("\(base)/\(stripped)") }
        }
        return out
    }

    /// `a/path` or `b/path` → `path`.
    static func strippingDiffPrefix(_ path: String) -> String? {
        guard path.hasPrefix("a/") || path.hasPrefix("b/") else { return nil }
        let stripped = String(path.dropFirst(2))
        return stripped.isEmpty ? nil : stripped
    }
}
