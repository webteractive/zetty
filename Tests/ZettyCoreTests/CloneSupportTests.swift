import Testing
import Foundation
@testable import ZettyCore

// MARK: - Naming

@Test func slugLowercasesAndDashesNonAlphanumerics() {
    #expect(CloneSupport.slug("My Cool App") == "my-cool-app")
    #expect(CloneSupport.slug("zetty") == "zetty")
    #expect(CloneSupport.slug("a__b!!c") == "a-b-c")
    #expect(CloneSupport.slug("--edgy--") == "edgy")
}

@Test func defaultCloneNameSkipsTakenNames() {
    #expect(CloneSupport.defaultCloneName(existing: []) == "fork-1")
    #expect(CloneSupport.defaultCloneName(existing: ["fork-1"]) == "fork-2")
    #expect(CloneSupport.defaultCloneName(existing: ["fork-1", "fork-3"]) == "fork-2")
}

// MARK: - Planning

@Test func planBuildsPathsNameAndBranch() throws {
    let plan = try CloneSupport.plan(
        sourceName: "zetty", sourceRootPath: "/Users/g/AI/zetty",
        cloneName: "fix-auth", takenCloneNames: [], home: "/Users/g").get()
    #expect(plan.cloneName == "fix-auth")
    #expect(plan.projectName == "zetty/fix-auth")
    #expect(plan.sourceRootPath == "/Users/g/AI/zetty")
    #expect(plan.targetPath == "/Users/g/.zetty/clones/zetty-fix-auth")
    #expect(plan.branchName == "fix-auth")
}

@Test func planDefaultsCloneNameWhenNil() throws {
    let plan = try CloneSupport.plan(
        sourceName: "zetty", sourceRootPath: "/Users/g/AI/zetty",
        cloneName: nil, takenCloneNames: ["fork-1"], home: "/Users/g").get()
    #expect(plan.cloneName == "fork-2")
    #expect(plan.targetPath == "/Users/g/.zetty/clones/zetty-fork-2")
}

@Test func planRejectsBadAndTakenNames() {
    let bad = CloneSupport.plan(sourceName: "z", sourceRootPath: "/s",
                                cloneName: "has space", takenCloneNames: [], home: "/h")
    #expect(bad == .failure(.invalidName("has space")))
    let empty = CloneSupport.plan(sourceName: "z", sourceRootPath: "/s",
                                  cloneName: "", takenCloneNames: [], home: "/h")
    #expect(empty == .failure(.invalidName("")))
    let dashFirst = CloneSupport.plan(sourceName: "z", sourceRootPath: "/s",
                                      cloneName: "-x", takenCloneNames: [], home: "/h")
    #expect(dashFirst == .failure(.invalidName("-x")))
    let taken = CloneSupport.plan(sourceName: "z", sourceRootPath: "/s",
                                  cloneName: "fork-1", takenCloneNames: ["fork-1"], home: "/h")
    #expect(taken == .failure(.nameTaken("fork-1")))
}

// MARK: - Git argument builders + parsers

@Test func gitArgumentBuilders() {
    #expect(CloneSupport.createBranchArgs(branch: "f1") == ["switch", "-c", "f1"])
    #expect(CloneSupport.fetchBackArgs(clonePath: "/c", branch: "f1")
            == ["fetch", "/c", "f1:f1"])
    #expect(CloneSupport.tipArgs == ["rev-parse", "HEAD"])
    #expect(CloneSupport.commitExistsArgs(sha: "abc123") == ["cat-file", "-e", "abc123^{commit}"])
}

@Test func parseTipSHATrimsAndValidates() {
    #expect(CloneSupport.parseTipSHA("abc123def\n") == "abc123def")
    #expect(CloneSupport.parseTipSHA("") == nil)
    #expect(CloneSupport.parseTipSHA("  \n") == nil)
    #expect(CloneSupport.parseTipSHA("not a sha!\n") == nil)
}

// MARK: - Removal classifier + delete guard

@Test func workStateClassification() {
    #expect(CloneSupport.workState(hasUncommittedChanges: false, hasUnfetchedCommits: false) == .clean)
    #expect(CloneSupport.workState(hasUncommittedChanges: false, hasUnfetchedCommits: true) == .unfetched)
    #expect(CloneSupport.workState(hasUncommittedChanges: true, hasUnfetchedCommits: false) == .dirty(unfetched: false))
    #expect(CloneSupport.workState(hasUncommittedChanges: true, hasUnfetchedCommits: true) == .dirty(unfetched: true))
}

@Test func isSafeToDeleteOnlyInsideClonesRoot() {
    let home = "/Users/g"
    #expect(CloneSupport.isSafeToDelete(path: "/Users/g/.zetty/clones/z-f1", home: home))
    #expect(!CloneSupport.isSafeToDelete(path: "/Users/g/.zetty/clones", home: home))       // the root itself
    #expect(!CloneSupport.isSafeToDelete(path: "/Users/g/.zetty/clones/", home: home))
    #expect(!CloneSupport.isSafeToDelete(path: "/Users/g/AI/zetty", home: home))
    #expect(!CloneSupport.isSafeToDelete(path: "/Users/g/.zetty/clones/../hooks", home: home)) // traversal
    #expect(!CloneSupport.isSafeToDelete(path: "/Users/g/.zetty/clonesX/z", home: home))     // prefix trick
}

// MARK: - Source eligibility + copy-noise tolerance (v0.1.20 hotfix)

@Test func homeAndAncestorsAreNotCloneableSources() {
    let home = "/Users/regine"
    #expect(!CloneSupport.isCloneableSource(path: "/Users/regine", home: home))    // home itself
    #expect(!CloneSupport.isCloneableSource(path: "/Users/regine/", home: home))   // trailing slash
    #expect(!CloneSupport.isCloneableSource(path: "/Users", home: home))           // ancestor
    #expect(!CloneSupport.isCloneableSource(path: "/", home: home))                // root
    #expect(CloneSupport.isCloneableSource(path: "/Users/regine/work/api", home: home))
    #expect(CloneSupport.isCloneableSource(path: "/Users/regineX", home: home))    // prefix trick
}

@Test func socketAndFifoOnlyCopyErrorsAreTolerable() {
    let socketsOnly = """
    cp: /src/.cursor/projects/worker.sock is a socket (not copied).
    cp: /src/Library/Herd/herd84.sock is a socket (not copied).
    """
    #expect(CloneSupport.copyErrorsAreTolerable(socketsOnly))
    let fifo = "cp: /src/tmp/pipe is a fifo (not copied)."
    #expect(CloneSupport.copyErrorsAreTolerable(fifo))
    let mixed = """
    cp: /src/a.sock is a socket (not copied).
    cp: /src/Library: unable to copy extended attributes: Operation not permitted
    """
    #expect(!CloneSupport.copyErrorsAreTolerable(mixed))
    // Nonzero exit with NO stderr is unexplained — never tolerable.
    #expect(!CloneSupport.copyErrorsAreTolerable(""))
    #expect(!CloneSupport.copyErrorsAreTolerable("  \n \n"))
}

@Test func summarizeCopyErrorsCapsLongDumps() {
    let short = "cp: one error"
    #expect(CloneSupport.summarizeCopyErrors(short) == short)
    let long = (1...40).map { "cp: error line \($0)" }.joined(separator: "\n")
    let summary = CloneSupport.summarizeCopyErrors(long, maxLines: 12)
    #expect(summary.hasPrefix("cp: error line 1\n"))
    #expect(summary.contains("cp: error line 12"))
    #expect(!summary.contains("cp: error line 13"))
    #expect(summary.hasSuffix("… and 28 more errors"))
}

// MARK: - Update-from-source readiness

@Test func updateReadinessNonGit() {
    #expect(CloneSupport.updateReadiness(isCloneGitWorkTree: false, isSourceGitWorkTree: true,
                                         cloneDirty: false) == .notGit)
    #expect(CloneSupport.updateReadiness(isCloneGitWorkTree: true, isSourceGitWorkTree: false,
                                         cloneDirty: false) == .notGit)
}

@Test func updateReadinessDirtyCloneRefused() {
    #expect(CloneSupport.updateReadiness(isCloneGitWorkTree: true, isSourceGitWorkTree: true,
                                         cloneDirty: true) == .cloneDirty)
}

@Test func updateReadinessReadyWhenCleanGitClone() {
    #expect(CloneSupport.updateReadiness(isCloneGitWorkTree: true, isSourceGitWorkTree: true,
                                         cloneDirty: false) == .ready)
}

// MARK: - Update arg builders

@Test func updateArgBuilders() {
    #expect(CloneSupport.updateFetchArgs(sourcePath: "/s") == ["fetch", "/s", "HEAD"])
    #expect(CloneSupport.alreadyCurrentArgs == ["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"])
    #expect(CloneSupport.updateMergeArgs == ["merge", "--no-edit", "FETCH_HEAD"])
    #expect(CloneSupport.conflictFilesArgs == ["diff", "--name-only", "--diff-filter=U"])
    #expect(CloneSupport.isGitWorkTreeArgs() == ["rev-parse", "--is-inside-work-tree"])
    #expect(CloneSupport.cloneStatusArgs() == ["status", "--porcelain"])
}

// MARK: - Sync guide

@Test func syncGuideBuildsAllPaths() {
    let g = CloneSupport.syncGuide(branch: "fork-1", clonePath: "/clone",
                                   sourcePath: "/src", defaultBranch: "main")
    #expect(g.branch == "fork-1")
    #expect(g.updateStep == "git fetch /src HEAD && git merge FETCH_HEAD   # or use “Update from Source”")
    #expect(g.prSteps == ["git push -u origin fork-1",
                          "Open a pull request against main."])
    #expect(g.localFallbackSteps == ["cd /src",
                                     "git fetch /clone fork-1",
                                     "git switch main",
                                     "git merge fork-1"])
}

// MARK: - Merge-to-source arg builders + option availability

@Test func mergeToSourceArgBuilders() {
    #expect(CloneSupport.hasRemoteArgs() == ["remote"])
    #expect(CloneSupport.fetchHeadArgs(from: "/c") == ["fetch", "/c", "HEAD"])
    #expect(CloneSupport.mergeAbortArgs == ["merge", "--abort"])
    #expect(CloneSupport.pushBranchArgs(branch: "fork-1") == ["push", "-u", "origin", "fork-1"])
}

@Test func mergeToSourceOptionsGitWithRemote() {
    let o = CloneSupport.mergeToSourceOptions(isCloneGit: true, isSourceGit: true, hasRemote: true)
    #expect(o == CloneSupport.MergeToSourceOptions(canMergeUpdates: true, canPushToBranch: true))
}

@Test func mergeToSourceOptionsGitNoRemote() {
    let o = CloneSupport.mergeToSourceOptions(isCloneGit: true, isSourceGit: true, hasRemote: false)
    #expect(o == CloneSupport.MergeToSourceOptions(canMergeUpdates: true, canPushToBranch: false))
}

@Test func mergeToSourceOptionsNonGitOffersNothing() {
    let a = CloneSupport.mergeToSourceOptions(isCloneGit: false, isSourceGit: true, hasRemote: true)
    let b = CloneSupport.mergeToSourceOptions(isCloneGit: true, isSourceGit: false, hasRemote: true)
    #expect(a == CloneSupport.MergeToSourceOptions(canMergeUpdates: false, canPushToBranch: false))
    #expect(b == CloneSupport.MergeToSourceOptions(canMergeUpdates: false, canPushToBranch: false))
}
