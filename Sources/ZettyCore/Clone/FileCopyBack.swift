import Foundation

/// Pure parsing + path logic for bringing a non-git clone's changed files back
/// into its source. Diff computation and file IO live in the app-layer
/// `FileCopyBackRunner`; this stays pure (mirrors the CloneSupport/CloneRunner split).
public enum FileCopyBack {

    public enum ChangeKind: Equatable, Sendable { case added, modified }

    /// A file the clone contributes to the source: new (`added`) or differing
    /// (`modified`). Deletions are never represented — a copy-back adds/updates,
    /// it never removes from the source.
    public struct FileChange: Equatable, Sendable {
        public let relPath: String
        public let kind: ChangeKind
        public init(relPath: String, kind: ChangeKind) {
            self.relPath = relPath
            self.kind = kind
        }
    }

    /// How a chosen change is written into the source.
    public enum Action: Equatable, Sendable {
        case copyNew    // added file — no source counterpart to conflict with
        case replace    // overwrite the source's file
        case keepBoth   // write the clone's version as "name 2.ext", keep the source's
    }

    public struct Decision: Equatable, Sendable {
        public let change: FileChange
        public let action: Action
        public init(change: FileChange, action: Action) {
            self.change = change
            self.action = action
        }
    }

    /// `git diff --no-index --no-renames --name-status -z <source> <clone>` — the
    /// changed-file list. (Run in the app layer; exit 1 = "differences", which is
    /// success.) `--no-renames` forces plain 2-field `status\0path\0` records even
    /// when the user's gitconfig sets `diff.renames`, so the pair-walk in
    /// `parseNameStatusZ` can never be misaligned by a 3-field rename/copy entry.
    public static func nameStatusArgs(sourceRoot: String, cloneRoot: String) -> [String] {
        ["diff", "--no-index", "--no-renames", "--name-status", "-z", sourceRoot, cloneRoot]
    }

    /// Parses `-z` name-status output (`status\0absPath\0` pairs) into the
    /// changes the clone contributes. `A`→added (path under the clone root),
    /// `M`→modified (path under the source root), `D`→dropped. Paths under a
    /// `.git/` directory are skipped defensively.
    public static func parseNameStatusZ(_ raw: String, sourceRoot: String,
                                        cloneRoot: String) -> [FileChange] {
        let tokens = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var out: [FileChange] = []
        var i = 0
        while i + 1 < tokens.count {
            let status = tokens[i]
            let path = tokens[i + 1]
            i += 2
            let root = (status == "A") ? cloneRoot : sourceRoot
            guard let rel = relativePath(path, under: root) else { continue }
            if rel == ".git" || rel.hasPrefix(".git/") { continue }
            switch status {
            case "A": out.append(FileChange(relPath: rel, kind: .added))
            case "M": out.append(FileChange(relPath: rel, kind: .modified))
            default: break   // D and anything else: not a copy-back contribution
            }
        }
        return out
    }

    /// Finder-style Keep-Both target: "name 2.ext" (last extension only; no
    /// extension → "name 2"; a leading-dot-only name like ".env" is treated as
    /// having no extension).
    public static func keepBothName(_ relPath: String) -> String {
        let dir = (relPath as NSString).deletingLastPathComponent
        let file = (relPath as NSString).lastPathComponent
        let base: String
        let suffix: String
        if let dot = file.lastIndex(of: "."), dot != file.startIndex {
            base = String(file[..<dot])
            suffix = String(file[dot...])   // includes the "."
        } else {
            base = file
            suffix = ""
        }
        let renamed = "\(base) 2\(suffix)"
        return dir.isEmpty ? renamed : "\(dir)/\(renamed)"
    }

    /// The path of `abs` relative to `root`, or nil if not under it.
    private static func relativePath(_ abs: String, under root: String) -> String? {
        let r = root.hasSuffix("/") ? root : root + "/"
        guard abs.hasPrefix(r) else { return abs == root ? "" : nil }
        return String(abs.dropFirst(r.count))
    }
}
