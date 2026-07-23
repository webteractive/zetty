# "Merge to Source…" Phase 1 (git cases) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the clone's "Update from Source" action with an adaptive **"Merge to Source…"** chooser offering two git strategies — **Merge updates** (sync from source, then merge the clone's branch back into the source locally) and **Push to branch** (sync, then push the clone's branch to the remote for a PR) — reusing the existing sync step.

**Architecture:** Pure git arg builders + a `MergeToSourceOptions` availability descriptor in `ZettyCore/Clone/CloneSupport.swift`; git IO (`hasRemote`, `mergeUpdates`, `pushBranch`) in `App/Sources/App/CloneRunner.swift` reusing `updateFromSource` for the shared sync; a chooser + result alerts in `TerminalViewController`; menu rename in `SidebarView`.

**Tech Stack:** Swift, AppKit, swift-testing, Tuist Xcode project + SPM, `/usr/bin/git` via `Process`.

## Global Constraints

- `ZettyCore` stays pure — no AppKit import.
- Never hardcode a color; `ZTheme.current.<token>Color`. (No new colors expected — NSAlert uses system styling.)
- Modified App files build via `tuist generate` + `xcodebuild`; no new files in this plan, so no `tuist clean` needed.
- Direction of the shared sync step is **source → clone** (`updateFromSource`, unchanged); **Merge updates** then goes **clone → source** (fast-forward because the sync already landed the source's tip in the clone); abort-on-conflict in the SOURCE (never leave the user's real project mid-merge). **Push to branch** pushes the clone's current branch to `origin`.
- Conflicts from the sync step are LEFT in the clone (existing policy) and stop the flow — the user resolves + commits, then re-invokes ("Merge to Source…" is resumable, not atomic through a conflict).
- Do not commit/push without being asked in other contexts — here each task ends with a commit using the message given; do not `git push`. Work on `main`, no new branch.
- CLI `zetty update-clone` stays as the sync-only step (unchanged this phase).

---

### Task 1: Pure git arg builders + `MergeToSourceOptions` (ZettyCore)

**Files:**
- Modify: `Sources/ZettyCore/Clone/CloneSupport.swift`
- Test: `Tests/ZettyCoreTests/CloneSupportTests.swift`

**Interfaces produced:**
- `static func hasRemoteArgs() -> [String]` → `["remote"]`
- `static func fetchHeadArgs(from path: String) -> [String]` → `["fetch", path, "HEAD"]`
- `static var mergeAbortArgs: [String]` → `["merge", "--abort"]`
- `static func pushBranchArgs(branch: String) -> [String]` → `["push", "-u", "origin", branch]`
- `struct MergeToSourceOptions: Equatable, Sendable { let canMergeUpdates: Bool; let canPushToBranch: Bool }`
- `static func mergeToSourceOptions(isCloneGit: Bool, isSourceGit: Bool, hasRemote: Bool) -> MergeToSourceOptions`
- (Reuses existing `updateMergeArgs` = `["merge","--no-edit","FETCH_HEAD"]` for the merge-back merge, and `conflictFilesArgs`, `cloneStatusArgs`, `isGitWorkTreeArgs`.)

- [ ] **Step 1: Write the failing tests** — append to `Tests/ZettyCoreTests/CloneSupportTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure** — `mise exec -- swift test --filter mergeToSource`
Expected: FAIL (undefined `hasRemoteArgs`/`MergeToSourceOptions`/`mergeToSourceOptions`).

- [ ] **Step 3: Implement** — inside `enum CloneSupport`, after the existing update-from-source section (near `conflictFilesArgs`):

```swift
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
```

- [ ] **Step 4: Run to verify pass** — `mise exec -- swift test --filter mergeToSource`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Clone/CloneSupport.swift Tests/ZettyCoreTests/CloneSupportTests.swift
git commit -m "feat(core): merge-to-source arg builders + option availability"
```

---

### Task 2: App IO — `hasRemote`, `mergeUpdates`, `pushBranch` (CloneRunner)

**Files:**
- Modify: `App/Sources/App/CloneRunner.swift`
- Verify: headless git integration script — Step 3.

**Interfaces produced:**
- `static func isGitWorkTree(in dir: String) -> Bool`
- `static func hasRemote(in dir: String) -> Bool`
- `enum CloneRunner.MergeBackOutcome: Equatable { case merged(summary:); case syncConflicts(files:); case sourceConflict(files:); case refused(String); case failed(String) }`
- `static func mergeUpdates(cloneRoot: String, sourceRoot: String) -> MergeBackOutcome`
- `enum CloneRunner.PushOutcome: Equatable { case pushed(summary:); case syncConflicts(files:); case refused(String); case failed(String) }`
- `static func pushBranch(cloneRoot: String, sourceRoot: String) -> PushOutcome`
- Consumes: existing `updateFromSource`, `currentBranch`, `runGit`, `runGitOutput`, `runGitResult`, `GitStatus.parseChangeCount`, and Task-1 `CloneSupport` builders.

- [ ] **Step 1: Implement helpers + outcomes** — add after `updateFromSource(...)` in `App/Sources/App/CloneRunner.swift`:

```swift
// MARK: - Merge to source (clone → source)

/// True iff `dir` is a git work tree.
static func isGitWorkTree(in dir: String) -> Bool {
    runGitOutput(CloneSupport.isGitWorkTreeArgs(), in: dir)?
        .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
}

/// True iff the repo at `dir` has at least one configured remote.
static func hasRemote(in dir: String) -> Bool {
    guard let out = runGitOutput(CloneSupport.hasRemoteArgs(), in: dir) else { return false }
    return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

enum MergeBackOutcome: Equatable {
    case merged(summary: String)      // clone's work landed in the source
    case syncConflicts(files: [String]) // the source→clone sync left conflicts in the clone
    case sourceConflict(files: [String]) // merge into the source conflicted; aborted, source untouched
    case refused(String)
    case failed(String)
}

/// Merge updates: first sync the source's latest into the clone (reused
/// `updateFromSource`); then, if that was clean, merge the clone's branch into
/// the SOURCE. Fast-forward in the normal case; abort-on-conflict in the source.
static func mergeUpdates(cloneRoot: String, sourceRoot: String) -> MergeBackOutcome {
    switch updateFromSource(cloneRoot: cloneRoot, sourceRoot: sourceRoot) {
    case .conflicts(let files): return .syncConflicts(files: files)
    case .refused(let m):       return .refused(m)
    case .failed(let m):        return .failed(m)
    case .updated, .upToDate:   break
    }
    // The source must be clean — a merge touches its working tree.
    let srcStatus = runGitOutput(CloneSupport.cloneStatusArgs(), in: sourceRoot) ?? ""
    if GitStatus.parseChangeCount(srcStatus) > 0 {
        return .refused("the source has uncommitted changes — commit or stash them first")
    }
    if let fetchErr = runGit(CloneSupport.fetchHeadArgs(from: cloneRoot), in: sourceRoot) {
        return .failed("fetching the clone into the source failed — nothing changed: \(fetchErr)")
    }
    let result = runGitResult(CloneSupport.updateMergeArgs, in: sourceRoot)
    if result.status == 0 {
        return .merged(summary: result.output.split(separator: "\n").first.map(String.init) ?? "merged")
    }
    let conflicts = (runGitOutput(CloneSupport.conflictFilesArgs, in: sourceRoot) ?? "")
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    _ = runGit(CloneSupport.mergeAbortArgs, in: sourceRoot)
    if !conflicts.isEmpty { return .sourceConflict(files: conflicts) }
    return .failed("merging into the source failed and was aborted: \(result.output)")
}

enum PushOutcome: Equatable {
    case pushed(summary: String)
    case syncConflicts(files: [String])
    case refused(String)
    case failed(String)
}

/// Push to branch: sync the source's latest into the clone, then push the
/// clone's current branch to `origin` (for a PR). The clone is not modified
/// beyond the sync; the source is not touched.
static func pushBranch(cloneRoot: String, sourceRoot: String) -> PushOutcome {
    switch updateFromSource(cloneRoot: cloneRoot, sourceRoot: sourceRoot) {
    case .conflicts(let files): return .syncConflicts(files: files)
    case .refused(let m):       return .refused(m)
    case .failed(let m):        return .failed(m)
    case .updated, .upToDate:   break
    }
    guard let branch = currentBranch(in: cloneRoot) else {
        return .refused("the clone has no current branch (detached HEAD?) — can't push")
    }
    let result = runGitResult(CloneSupport.pushBranchArgs(branch: branch), in: cloneRoot)
    if result.status == 0 {
        let line = result.output.split(separator: "\n").last.map(String.init) ?? "pushed \(branch)"
        return .pushed(summary: line)
    }
    return .failed("push failed: \(result.output)")
}
```

- [ ] **Step 2: Regenerate + build**

```
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Headless verification script** — save to `/private/tmp/claude-502/-Users-glenbangkila-AI-zetty/c1e1f3d7-066b-409e-955b-f16c4b8eca29/scratchpad/mergeback-it.sh` and run with `/bin/sh`. It exercises the exact git sequence `mergeUpdates`/`pushBranch` use:

```bash
#!/bin/sh
set -e
base=$(mktemp -d); src="$base/src"; clone="$base/clone"; bare="$base/remote.git"
git init -q "$src"; cd "$src"; git config user.email t@t; git config user.name t
printf 'a\n' > f.txt; git add .; git commit -qm init
cp -R "$src" "$clone"; git -C "$clone" switch -qc fork-1
git -C "$clone" config user.email t@t; git -C "$clone" config user.name t
# clone does work; source advances on a non-conflicting file
printf 'clone\n' > "$clone/new.txt"; git -C "$clone" add .; git -C "$clone" commit -qm clone-work
printf 'a\nsrc\n' > "$src/g.txt"; git -C "$src" add .; git -C "$src" commit -qm src-adv
# --- Merge updates: sync source->clone, then merge clone->source ---
git -C "$clone" fetch -q "$src" HEAD && git -C "$clone" merge --no-edit FETCH_HEAD >/dev/null
git -C "$clone" diff --name-only --diff-filter=U    # expect empty (clean sync)
git -C "$src" fetch -q "$clone" HEAD && git -C "$src" merge --no-edit FETCH_HEAD >/dev/null && echo "MERGE-UPDATES-OK"
git -C "$src" cat-file -e HEAD:new.txt && echo "CLONE-WORK-IN-SOURCE-OK"   # clone's file now in source
# --- Push to branch: bare remote + push clone branch ---
git init -q --bare "$bare"; git -C "$clone" remote add origin "$bare"
git -C "$clone" remote | grep -q origin && echo "HAS-REMOTE-OK"
git -C "$clone" push -q -u origin fork-1 && echo "PUSH-BRANCH-OK"
git -C "$bare" rev-parse --verify -q fork-1 >/dev/null && echo "BRANCH-ON-REMOTE-OK"
rm -rf "$base"
```

Expected markers: `MERGE-UPDATES-OK`, `CLONE-WORK-IN-SOURCE-OK`, `HAS-REMOTE-OK`, `PUSH-BRANCH-OK`, `BRANCH-ON-REMOTE-OK`. Paste output into the report.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/App/CloneRunner.swift
git commit -m "feat(app): CloneRunner mergeUpdates + pushBranch (clone→source strategies)"
```

---

### Task 3: UI — "Merge to Source…" chooser + strategy wiring

**Files:**
- Modify: `App/Sources/App/SidebarView.swift`
- Modify: `App/Sources/App/TerminalViewController.swift`
- Modify: `App/Sources/App/CloneMergeGuideView.swift` (tip copy)

**Interfaces:**
- Rename `SidebarView.onUpdateClone` → `onMergeToSource`; `updateCloneMenuClicked` → `mergeToSourceMenuClicked`; menu title "Update from Source" → "Merge to Source\u{2026}".
- Rename `TerminalViewController.confirmUpdateClone(at:)` → `confirmMergeToSource(at:)`; replace `presentUpdateOutcome` with `presentMergeBackOutcome`/`presentPushOutcome`; add `presentMergeToSourceChooser(...)`.
- Consumes Task-1/2 `CloneSupport.mergeToSourceOptions`, `CloneRunner.isGitWorkTree`/`hasRemote`/`mergeUpdates`/`pushBranch`.

- [ ] **Step 1: SidebarView — rename callback, handler, menu item**

In `App/Sources/App/SidebarView.swift`:
- Line ~125-126: rename the doc comment + property to:
```swift
    /// Called with the project index for the context menu's "Merge to Source…".
    var onMergeToSource: ((Int) -> Void)?
```
- Rename the handler (~625):
```swift
    @objc private func mergeToSourceMenuClicked(_ sender: NSMenuItem) {
        let projectIndex = sender.tag
        guard projects.indices.contains(projectIndex) else { return }
        onMergeToSource?(projectIndex)
    }
```
- Update the menu item block (~703-709):
```swift
            if projects[p].isClone {
                let merge = NSMenuItem(title: "Merge to Source\u{2026}",
                                       action: #selector(mergeToSourceMenuClicked(_:)),
                                       keyEquivalent: "")
                merge.target = self
                merge.tag = p
                menu.addItem(merge)
            }
```

- [ ] **Step 2: TerminalViewController — wiring + chooser + outcomes**

In `App/Sources/App/TerminalViewController.swift`:
- Update the wiring (~539):
```swift
        sidebar.onMergeToSource = { [weak self] index in
            self?.confirmMergeToSource(at: index)
        }
```
- Replace `confirmUpdateClone(at:)` and `presentUpdateOutcome(_:cloneName:)` (the whole ~2610-2671 block) with:

```swift
    /// Probes the source's git/remote state off-main, then presents the
    /// "Merge to Source…" chooser (Merge updates / Push to branch, per
    /// availability) and runs the chosen strategy off-main. Nothing is deleted.
    private func confirmMergeToSource(at index: Int) {
        guard workspace.projects.indices.contains(index) else { return }
        let clone = workspace.projects[index]
        guard let sourceRoot = clone.cloneSource else { return }
        let cloneRoot = clone.rootPath
        let cloneName = clone.name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let options = CloneSupport.mergeToSourceOptions(
                isCloneGit: CloneRunner.isGitWorkTree(in: cloneRoot),
                isSourceGit: CloneRunner.isGitWorkTree(in: sourceRoot),
                hasRemote: CloneRunner.hasRemote(in: cloneRoot))
            DispatchQueue.main.async {
                self?.presentMergeToSourceChooser(options: options, cloneRoot: cloneRoot,
                                                  sourceRoot: sourceRoot, cloneName: cloneName)
            }
        }
    }

    private func presentMergeToSourceChooser(options: CloneSupport.MergeToSourceOptions,
                                             cloneRoot: String, sourceRoot: String, cloneName: String) {
        guard options.canMergeUpdates else {
            // Non-git source — the file copy-back (diff modal) ships in Phase 2.
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Can't merge “\(cloneName)” to its source yet"
            alert.informativeText = "This clone's source isn't a git repository. Bringing "
                + "changes back for non-git projects (a file diff + copy-back) is coming soon."
            alert.addButton(withTitle: "OK")
            if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
            else { alert.runModal() }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Merge “\(cloneName)” to its source?"
        alert.informativeText = "First updates this clone from the source (resolve any conflicts "
            + "in the clone, then re-run). Then:\n• Merge updates — merges the clone's work into "
            + "the source locally.\n• Push to branch — pushes the clone's branch to the remote so "
            + "you can open a PR."
        alert.addButton(withTitle: "Merge updates")
        if options.canPushToBranch { alert.addButton(withTitle: "Push to branch") }
        alert.addButton(withTitle: "Cancel")

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = CloneRunner.mergeUpdates(cloneRoot: cloneRoot, sourceRoot: sourceRoot)
                    DispatchQueue.main.async { self.presentMergeBackOutcome(outcome, cloneName: cloneName) }
                }
            } else if options.canPushToBranch && response == .alertSecondButtonReturn {
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = CloneRunner.pushBranch(cloneRoot: cloneRoot, sourceRoot: sourceRoot)
                    DispatchQueue.main.async { self.presentPushOutcome(outcome, cloneName: cloneName) }
                }
            }
            // otherwise Cancel — no-op
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: run) }
        else { run(alert.runModal()) }
    }

    private func presentMergeBackOutcome(_ outcome: CloneRunner.MergeBackOutcome, cloneName: String) {
        let alert = NSAlert()
        switch outcome {
        case .merged(let summary):
            alert.alertStyle = .informational
            alert.messageText = "Merged “\(cloneName)” into its source"
            alert.informativeText = summary
        case .syncConflicts(let files):
            alert.alertStyle = .warning
            alert.messageText = "Resolve conflicts in the clone first"
            alert.informativeText = "Updating the clone from the source left conflicts. Resolve "
                + "these in the clone and commit, then run Merge to Source again:\n"
                + files.joined(separator: "\n")
        case .sourceConflict(let files):
            alert.alertStyle = .warning
            alert.messageText = "Merge conflict in the source — nothing changed"
            alert.informativeText = "The source repo is untouched. Resolve manually. Conflicting "
                + "files:\n" + files.joined(separator: "\n")
        case .refused(let message):
            alert.alertStyle = .warning
            alert.messageText = "Nothing merged"
            alert.informativeText = message
        case .failed(let message):
            alert.alertStyle = .critical
            alert.messageText = "Merge failed"
            alert.informativeText = message
        }
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    private func presentPushOutcome(_ outcome: CloneRunner.PushOutcome, cloneName: String) {
        let alert = NSAlert()
        switch outcome {
        case .pushed(let summary):
            alert.alertStyle = .informational
            alert.messageText = "Pushed “\(cloneName)” to its remote"
            alert.informativeText = summary + "\n\nOpen a pull request to land it in the source."
        case .syncConflicts(let files):
            alert.alertStyle = .warning
            alert.messageText = "Resolve conflicts in the clone first"
            alert.informativeText = "Updating the clone from the source left conflicts. Resolve "
                + "these in the clone and commit, then run Merge to Source again:\n"
                + files.joined(separator: "\n")
        case .refused(let message):
            alert.alertStyle = .warning
            alert.messageText = "Nothing pushed"
            alert.informativeText = message
        case .failed(let message):
            alert.alertStyle = .critical
            alert.messageText = "Push failed"
            alert.informativeText = message
        }
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }
```

- [ ] **Step 3: Update the banner popover tip copy**

In `App/Sources/App/CloneMergeGuideView.swift`, update the trailing tip line so it names the new action. Change the `Self.body("Tip: …")` line to:

```swift
            Self.body("Tip: “Merge to Source…” (right-click the clone) updates from the "
                + "source and then merges your work back or pushes your branch for a PR."),
```

- [ ] **Step 4: Regenerate + build**

```
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED. (Confirm no stale `onUpdateClone`/`confirmUpdateClone`/`presentUpdateOutcome` references remain — grep them; expect none.)

- [ ] **Step 5: Commit**

```bash
git add App/Sources/App/SidebarView.swift App/Sources/App/TerminalViewController.swift App/Sources/App/CloneMergeGuideView.swift
git commit -m "feat(app): Merge to Source… chooser (Merge updates / Push to branch)"
```

---

### Task 4: Docs (README + CLAUDE.md/AGENTS.md)

**Files:** `README.md`, `CLAUDE.md`, `AGENTS.md`

- [ ] **Step 1: README** — in the clone section's "Bringing clone work back", update the GUI action from "Update from Source" to **"Merge to Source…"** and describe the two strategies (Merge updates = local merge back; Push to branch = push for a PR; requires a remote), keeping the note that it first updates the clone from the source and leaves conflicts in the clone. Note non-git sources ("file copy-back") are coming. Keep `zetty update-clone` in the CLI list as the sync step.

- [ ] **Step 2: CLAUDE.md + AGENTS.md** — update the clone-section paragraph (the one added at CLAUDE.md ~272) to describe the new **"Merge to Source…"** chooser and the `mergeUpdates`/`pushBranch` app-layer strategies + `mergeToSourceOptions` gating, replacing the "Update from Source"-only wording. Insert the SAME edit in both files, byte-identical.

- [ ] **Step 3: Verify parity** — `diff CLAUDE.md AGENTS.md` → no output.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md AGENTS.md
git commit -m "docs: Merge to Source… chooser (Merge updates / Push to branch)"
```

---

## Self-Review

- **Spec coverage:** chooser entry point (Task 3), Merge updates clone→source local (Tasks 1-2), Push to branch to remote (Tasks 1-2), remote gating (Task 1 `mergeToSourceOptions` + Task 2 `hasRemote`), sync-conflict-stops-flow (Task 2 maps `.conflicts`→`.syncConflicts`), abort-on-conflict in source (Task 2), non-git placeholder → Phase 2 (Task 3 chooser guard), docs (Task 4). ✅
- **Placeholders:** none — full code in every code step; commands have expected output/markers. ✅
- **Type consistency:** `MergeToSourceOptions`(`canMergeUpdates`/`canPushToBranch`) identical Tasks 1/2/3; `MergeBackOutcome`(`.merged`/`.syncConflicts`/`.sourceConflict`/`.refused`/`.failed`) identical Tasks 2/3; `PushOutcome`(`.pushed`/`.syncConflicts`/`.refused`/`.failed`) identical Tasks 2/3; `mergeUpdates`/`pushBranch`/`isGitWorkTree`/`hasRemote` signatures identical Tasks 2/3. ✅
- **TDD note:** Task 1 pure is red→green TDD. Tasks 2-3 are git IO + AppKit (TCC-denied GUI) — verified by the headless git script (Task 2) and the build gate; live chooser behavior verified by the user.
