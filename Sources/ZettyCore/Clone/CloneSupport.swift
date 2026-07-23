import Foundation

/// Everything decidable about a clone before touching the filesystem: the
/// target directory under `~/.zetty/clones/`, the display name, and the git
/// branch the clone's work will live on.
public struct ClonePlan: Equatable, Sendable {
    public let cloneName: String       // "fork-1"
    public let projectName: String     // "zetty/fork-1" (sidebar + CLI name)
    public let sourceRootPath: String
    public let targetPath: String      // <home>/.zetty/clones/zetty-fork-1
    public let branchName: String      // "fork-1"

    public init(cloneName: String, projectName: String, sourceRootPath: String,
                targetPath: String, branchName: String) {
        self.cloneName = cloneName
        self.projectName = projectName
        self.sourceRootPath = sourceRootPath
        self.targetPath = targetPath
        self.branchName = branchName
    }
}

public enum CloneError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case nameTaken(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let n):
            return "invalid clone name \"\(n)\" — use letters, digits, '.', '-', '_' (must start alphanumeric)"
        case .nameTaken(let n):
            return "clone name \"\(n)\" is already in use for this project"
        }
    }
}

/// What a clone would lose if deleted right now.
public enum CloneWorkState: Equatable, Sendable {
    case clean                     // nothing to save (no commits beyond source, no dirty files)
    case unfetched                 // committed work the source repo doesn't have yet
    case dirty(unfetched: Bool)    // uncommitted changes (possibly plus unfetched commits)
}

/// Whether the source's latest can be auto-merged INTO the clone right now.
public enum UpdateReadiness: Equatable, Sendable {
    case notGit      // clone or source is not a git work tree
    case cloneDirty  // clone has uncommitted changes — commit before pulling source in
    case ready
}

/// Pure planning + parsing for project clones. Process spawning (`cp`, `git`)
/// lives in the app layer (`CloneRunner`) — same split as `GitStatus`.
public enum CloneSupport {

    /// The zetty-owned directory all clone copies live under.
    public static func clonesRoot(home: String) -> String {
        (home as NSString).appendingPathComponent(".zetty/clones")
    }

    /// Lowercased, non-alphanumeric runs collapsed to single dashes, trimmed.
    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var pendingDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out
    }

    /// "fork-1", "fork-2", … skipping names already in use.
    public static func defaultCloneName(existing: Set<String>) -> String {
        var n = 1
        while existing.contains("fork-\(n)") { n += 1 }
        return "fork-\(n)"
    }

    /// Letters/digits/'.'/'-'/'_' only, first character alphanumeric, ≤64 chars.
    public static func isValidCloneName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64,
              let first = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }

    /// Validates the clone name (nil → next free default) and derives every
    /// path/name the clone needs. Filesystem existence checks are the
    /// caller's job — this stays pure.
    public static func plan(
        sourceName: String, sourceRootPath: String, cloneName: String?,
        takenCloneNames: Set<String>, home: String
    ) -> Result<ClonePlan, CloneError> {
        let name: String
        if let cloneName {
            guard isValidCloneName(cloneName) else { return .failure(.invalidName(cloneName)) }
            guard !takenCloneNames.contains(cloneName) else { return .failure(.nameTaken(cloneName)) }
            name = cloneName
        } else {
            name = defaultCloneName(existing: takenCloneNames)
        }
        let target = (clonesRoot(home: home) as NSString)
            .appendingPathComponent("\(slug(sourceName))-\(name)")
        return .success(ClonePlan(
            cloneName: name,
            projectName: "\(sourceName)/\(name)",
            sourceRootPath: sourceRootPath,
            targetPath: target,
            branchName: name
        ))
    }

    // MARK: - Git argument builders (run via `git -C <dir>` in the app layer)

    /// Inside the CLONE right after copying: put its work on its own branch.
    public static func createBranchArgs(branch: String) -> [String] {
        ["switch", "-c", branch]
    }

    /// Inside the SOURCE at removal: land the clone's branch as a local branch.
    public static func fetchBackArgs(clonePath: String, branch: String) -> [String] {
        ["fetch", clonePath, "\(branch):\(branch)"]
    }

    /// Inside the CLONE: its current tip commit.
    public static let tipArgs = ["rev-parse", "HEAD"]

    /// Inside the SOURCE: exit 0 iff the commit object already exists there
    /// (i.e. the clone's work was already fetched or never diverged).
    public static func commitExistsArgs(sha: String) -> [String] {
        ["cat-file", "-e", "\(sha)^{commit}"]
    }

    /// Trims `rev-parse HEAD` output to a hex SHA; nil for empty/garbage.
    public static func parseTipSHA(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
        else { return nil }
        return trimmed
    }

    // MARK: - Source eligibility + copy-noise tolerance

    /// Whether a directory is safe to clone at all. The user's home directory
    /// — or any ancestor of it — is not: copying it drags in the whole
    /// account (TCC-protected ~/Library, sockets, potentially hundreds of
    /// GB). Legacy pre-Home workspaces have ordinary projects rooted at ~,
    /// so this must be checked by PATH, not just the `isHome` flag.
    public static func isCloneableSource(path: String, home: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let h = (home as NSString).standardizingPath
        return p != "/" && p != h && !h.hasPrefix(p + "/")
    }

    /// `cp` exits nonzero when ANY entry fails, but some failures are
    /// expected noise: sockets and fifos can't be copied by cp at all and
    /// are recreatable runtime artifacts (dev dirs are full of `.sock`
    /// files). A copy whose only errors are those still counts as success.
    /// Nonzero exit with no stderr at all is unexplained — never tolerable.
    public static func copyErrorsAreTolerable(_ stderr: String) -> Bool {
        let lines = stderr.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy {
            $0.hasSuffix("is a socket (not copied).") || $0.hasSuffix("is a fifo (not copied).")
        }
    }

    /// Caps a cp stderr dump to something an alert can actually show.
    public static func summarizeCopyErrors(_ stderr: String, maxLines: Int = 12) -> String {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxLines else {
            return stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines.prefix(maxLines).joined(separator: "\n")
            + "\n… and \(lines.count - maxLines) more errors"
    }

    // MARK: - Removal

    public static func workState(hasUncommittedChanges: Bool, hasUnfetchedCommits: Bool) -> CloneWorkState {
        if hasUncommittedChanges { return .dirty(unfetched: hasUnfetchedCommits) }
        return hasUnfetchedCommits ? .unfetched : .clean
    }

    /// Belt-and-braces delete guard: only paths STRICTLY inside
    /// `~/.zetty/clones/` (not the root itself, no `..` traversal) may be
    /// deleted by zetty.
    public static func isSafeToDelete(path: String, home: String) -> Bool {
        let root = clonesRoot(home: home)
        let normalized = (path as NSString).standardizingPath
        return normalized.hasPrefix(root + "/") && normalized != root
    }

    // MARK: - Update from source (source → clone)

    /// `.ready` iff both clone and source are git work trees and the clone's
    /// working tree is clean (a merge would otherwise be refused / risk local work).
    public static func updateReadiness(isCloneGitWorkTree: Bool, isSourceGitWorkTree: Bool,
                                       cloneDirty: Bool) -> UpdateReadiness {
        guard isCloneGitWorkTree, isSourceGitWorkTree else { return .notGit }
        return cloneDirty ? .cloneDirty : .ready
    }

    public static func isGitWorkTreeArgs() -> [String] { ["rev-parse", "--is-inside-work-tree"] }
    public static func cloneStatusArgs() -> [String] { ["status", "--porcelain"] }
    /// Fetch the SOURCE's current branch tip into FETCH_HEAD (no named refspec).
    public static func updateFetchArgs(sourcePath: String) -> [String] { ["fetch", sourcePath, "HEAD"] }
    /// Exit 0 iff the fetched source tip is already an ancestor of the clone (up to date).
    public static var alreadyCurrentArgs: [String] { ["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"] }
    public static var updateMergeArgs: [String] { ["merge", "--no-edit", "FETCH_HEAD"] }
    public static var conflictFilesArgs: [String] { ["diff", "--name-only", "--diff-filter=U"] }

    /// Copy-pasteable steps for the feature-branch flow: update from source, PR
    /// (primary), and a no-origin local merge-into-source fallback.
    public struct SyncGuide: Equatable, Sendable {
        public let branch: String
        public let updateStep: String
        public let prSteps: [String]
        public let localFallbackSteps: [String]
        public init(branch: String, updateStep: String, prSteps: [String], localFallbackSteps: [String]) {
            self.branch = branch
            self.updateStep = updateStep
            self.prSteps = prSteps
            self.localFallbackSteps = localFallbackSteps
        }
    }

    public static func syncGuide(branch: String, clonePath: String, sourcePath: String,
                                 defaultBranch: String) -> SyncGuide {
        SyncGuide(
            branch: branch,
            updateStep: "git fetch \(sourcePath) HEAD && git merge FETCH_HEAD"
                + "   # or use “Update from Source”",
            prSteps: [
                "git push -u origin \(branch)",
                "Open a pull request against \(defaultBranch).",
            ],
            localFallbackSteps: [
                "cd \(sourcePath)",
                "git fetch \(clonePath) \(branch)",
                "git switch \(defaultBranch)",
                "git merge \(branch)",
            ])
    }

    // MARK: - Merge to source (clone → source strategies)

    public static func hasRemoteArgs() -> [String] { ["remote"] }
    /// Fetch a path's current HEAD into FETCH_HEAD (generalizes updateFetchArgs).
    public static func fetchHeadArgs(from path: String) -> [String] { ["fetch", path, "HEAD"] }
    public static var mergeAbortArgs: [String] { ["merge", "--abort"] }
    public static func pushBranchArgs(branch: String) -> [String] { ["push", "-u", "origin", branch] }

    /// Which clone→source strategies are available for a given source. Non-git
    /// (either side) offers neither here — the non-git file copy-back is Phase 2.
    public struct MergeToSourceOptions: Equatable, Sendable {
        public let canMergeUpdates: Bool
        public let canPushToBranch: Bool
        public init(canMergeUpdates: Bool, canPushToBranch: Bool) {
            self.canMergeUpdates = canMergeUpdates
            self.canPushToBranch = canPushToBranch
        }
    }

    public static func mergeToSourceOptions(isCloneGit: Bool, isSourceGit: Bool,
                                            hasRemote: Bool) -> MergeToSourceOptions {
        let git = isCloneGit && isSourceGit
        return MergeToSourceOptions(canMergeUpdates: git, canPushToBranch: git && hasRemote)
    }
}
