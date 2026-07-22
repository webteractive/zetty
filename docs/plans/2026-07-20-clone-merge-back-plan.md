# Clone "Update from Source" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the feature-branch flow for getting clone work back to its source (update from source → fix conflicts → PR), and give users a safe automated **Update from Source** action (GUI + CLI) that merges the source's latest branch into the clone, leaving any conflicts in the clone to resolve.

**Architecture:** Pure classification/instruction text + git arg builders live in `ZettyCore/Clone/CloneSupport.swift` (unit-tested with swift-testing); git process IO lives in the app-layer `CloneRunner`; the CLI `update-clone` verb is routed as a slow verb in `AppDelegate.startControlSocket` (plan on main → git off-main → report); the instruction popover hangs off `CloneWarningBanner`; the GUI action hangs off the clone-row context menu.

**Tech Stack:** Swift, AppKit, swift-testing (`import Testing`), Tuist-generated Xcode project, `/usr/bin/git` via `Process`.

## Global Constraints

- `ZettyCore` stays pure — no AppKit import. (CLAUDE.md Layout/Conventions)
- Never hardcode a color — read `ZTheme.current.<token>Color`; terminal-adjacent UI uses `ZTheme.monoFont`. (CLAUDE.md Design rules 1–2)
- After adding/removing a source file, regenerate: `mise exec -- tuist generate --no-open` then build; run `tuist clean` first when files were added (resources gotcha). (CLAUDE.md)
- Document the feature in `README.md`; keep `CLAUDE.md` and `AGENTS.md` byte-identical. (CLAUDE.md Conventions)
- Do not commit or push without being asked; no `Co-Authored-By`, no session link. (CLAUDE.md + global)
- Work on the current branch (`main`); do not create a branch. (CLAUDE.md)
- Direction is **source → clone**. Fetch the **source's current HEAD** into `FETCH_HEAD` (no named refspec) so a clone on `<name>` OR a fallback `main` both update.
- Conflict policy is **leave-conflicts-in-the-clone** (do NOT abort): resolving conflicts in the clone is the intended step. Update from Source never deletes anything.

---

### Task 1: `UpdateReadiness`, git arg builders, and `syncGuide` (pure, ZettyCore)

**Files:**
- Modify: `Sources/ZettyCore/Clone/CloneSupport.swift`
- Test: `Tests/ZettyCoreTests/CloneSupportTests.swift`

**Interfaces:**
- Produces:
  - `enum UpdateReadiness: Equatable, Sendable { case notGit, cloneDirty, ready }`
  - `static func updateReadiness(isCloneGitWorkTree: Bool, isSourceGitWorkTree: Bool, cloneDirty: Bool) -> UpdateReadiness`
  - `static func isGitWorkTreeArgs() -> [String]` → `["rev-parse", "--is-inside-work-tree"]`
  - `static func cloneStatusArgs() -> [String]` → `["status", "--porcelain"]`
  - `static func updateFetchArgs(sourcePath: String) -> [String]` → `["fetch", sourcePath, "HEAD"]`
  - `static var alreadyCurrentArgs: [String]` → `["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"]`
  - `static var updateMergeArgs: [String]` → `["merge", "--no-edit", "FETCH_HEAD"]`
  - `static var conflictFilesArgs: [String]` → `["diff", "--name-only", "--diff-filter=U"]`
  - `struct SyncGuide: Equatable, Sendable { let branch: String; let updateStep: String; let prSteps: [String]; let localFallbackSteps: [String] }`
  - `static func syncGuide(branch: String, clonePath: String, sourcePath: String, defaultBranch: String) -> SyncGuide`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ZettyCoreTests/CloneSupportTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- swift test --filter update`
Expected: FAIL — `updateReadiness` / `UpdateReadiness` / `syncGuide` are undefined.

- [ ] **Step 3: Write the minimal implementation**

In `Sources/ZettyCore/Clone/CloneSupport.swift`, add after the existing `CloneWorkState` enum:

```swift
/// Whether the source's latest can be auto-merged INTO the clone right now.
public enum UpdateReadiness: Equatable, Sendable {
    case notGit      // clone or source is not a git work tree
    case cloneDirty  // clone has uncommitted changes — commit before pulling source in
    case ready
}
```

Inside `enum CloneSupport`, add:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- swift test --filter update` then `mise exec -- swift test --filter syncGuide`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Clone/CloneSupport.swift Tests/ZettyCoreTests/CloneSupportTests.swift
git commit -m "feat(core): update-from-source readiness, git arg builders, sync guide"
```

---

### Task 2: `CloneRunner.updateFromSource(...)` — git process IO (app layer)

**Files:**
- Modify: `App/Sources/App/CloneRunner.swift`
- Verify: integration script (headless; no GUI/TCC) — see Step 3.

**Interfaces:**
- Consumes: `CloneSupport.updateReadiness`, `isGitWorkTreeArgs`, `cloneStatusArgs`, `updateFetchArgs`, `alreadyCurrentArgs`, `updateMergeArgs`, `conflictFilesArgs`; existing `CloneRunner.runGit`, `runGitOutput`, `GitStatus.parseChangeCount`.
- Produces:
  - `enum CloneRunner.UpdateOutcome: Equatable { case updated(summary: String); case upToDate; case conflicts(files: [String]); case refused(String); case failed(String) }`
  - `static func updateFromSource(cloneRoot: String, sourceRoot: String) -> UpdateOutcome`
  - `static func runGitResult(_ args: [String], in directory: String) -> (status: Int32, output: String)`
  - `static func gitSucceeds(_ args: [String], in directory: String) -> Bool`

- [ ] **Step 1: Add helpers**

In `App/Sources/App/CloneRunner.swift`, after `runGitOutput(...)`, add:

```swift
/// Runs `git -C <directory> <args>`, returning the exit status and combined
/// stdout+stderr (trimmed) — used where the merge summary/conflict text matters.
static func runGitResult(_ args: [String], in directory: String) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (process.terminationStatus, text)
}

/// True iff `git -C <directory> <args>` exits 0 (for predicate git commands).
static func gitSucceeds(_ args: [String], in directory: String) -> Bool {
    runGitResult(args, in: directory).status == 0
}
```

- [ ] **Step 2: Add `UpdateOutcome` and `updateFromSource(...)`**

In `App/Sources/App/CloneRunner.swift`, add a new section after `fetchBack(...)`:

```swift
// MARK: - Update from source (source → clone)

enum UpdateOutcome: Equatable {
    case updated(summary: String)  // source's latest merged into the clone cleanly
    case upToDate                  // clone already contains the source tip
    case conflicts(files: [String])// merge left in progress in the clone to resolve
    case refused(String)           // notGit / cloneDirty
    case failed(String)            // fetch/merge failed otherwise
}

/// Merges the SOURCE's current branch tip into the CLONE (leave-conflicts).
/// Blocking — run off-main. Nothing is deleted; on conflict the clone is left
/// mid-merge for the user to resolve, then commit + PR.
static func updateFromSource(cloneRoot: String, sourceRoot: String) -> UpdateOutcome {
    let isCloneGit = (runGitOutput(CloneSupport.isGitWorkTreeArgs(), in: cloneRoot)?
        .trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    let isSourceGit = (runGitOutput(CloneSupport.isGitWorkTreeArgs(), in: sourceRoot)?
        .trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    let cloneDirty = GitStatus.parseChangeCount(
        runGitOutput(CloneSupport.cloneStatusArgs(), in: cloneRoot) ?? "") > 0

    switch CloneSupport.updateReadiness(isCloneGitWorkTree: isCloneGit,
                                        isSourceGitWorkTree: isSourceGit, cloneDirty: cloneDirty) {
    case .notGit:
        return .refused("clone or source is not a git repository — nothing to update")
    case .cloneDirty:
        return .refused("clone has uncommitted changes — commit them first, then update")
    case .ready:
        break
    }

    if let fetchError = runGit(CloneSupport.updateFetchArgs(sourcePath: sourceRoot), in: cloneRoot) {
        return .failed("fetch from source failed — nothing changed: \(fetchError)")
    }
    if gitSucceeds(CloneSupport.alreadyCurrentArgs, in: cloneRoot) {
        return .upToDate
    }
    let result = runGitResult(CloneSupport.updateMergeArgs, in: cloneRoot)
    if result.status == 0 {
        let summary = result.output.split(separator: "\n").first.map(String.init) ?? "updated"
        return .updated(summary: summary)
    }
    // Merge failed. If it's a conflict, LEAVE it in the clone to resolve.
    let conflicts = (runGitOutput(CloneSupport.conflictFilesArgs, in: cloneRoot) ?? "")
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    if !conflicts.isEmpty { return .conflicts(files: conflicts) }
    // Non-conflict failure — abort so the clone isn't left half-merged.
    _ = runGit(["merge", "--abort"], in: cloneRoot)
    return .failed("update failed and was aborted: \(result.output)")
}
```

- [ ] **Step 3: Verify headlessly with a git integration script**

Save and run `/private/tmp/claude-502/-Users-glenbangkila-AI-zetty/c1e1f3d7-066b-409e-955b-f16c4b8eca29/scratchpad/update-it.sh`:

```bash
#!/bin/sh
set -e
base=$(mktemp -d); src="$base/src"; clone="$base/clone"
git init -q "$src"; cd "$src"; git config user.email t@t; git config user.name t
printf 'a\n' > f.txt; git add .; git commit -qm init
cp -R "$src" "$clone"; git -C "$clone" switch -qc fork-1
# Source advances; clone does independent (non-conflicting) work:
printf 'a\nsrc\n' > "$src/g.txt"; git -C "$src" add .; git -C "$src" commit -qm src-new
printf 'clone\n' >> "$clone/h.txt"; git -C "$clone" add .; git -C "$clone" commit -qm clone-work
# Update clone from source (should merge cleanly):
git -C "$clone" fetch -q "$src" HEAD
if git -C "$clone" merge-base --is-ancestor FETCH_HEAD HEAD; then echo "UNEXPECTED-UPTODATE"; fi
git -C "$clone" merge --no-edit FETCH_HEAD >/dev/null && echo "CLEAN-UPDATE-OK"
git -C "$clone" diff --name-only --diff-filter=U   # expect empty
echo "--- up-to-date case ---"
git -C "$clone" fetch -q "$src" HEAD
git -C "$clone" merge-base --is-ancestor FETCH_HEAD HEAD && echo "UPTODATE-OK"
echo "--- conflict case ---"
printf 'a\nSRC\n' > "$src/f.txt"; git -C "$src" commit -qam src-conf
printf 'a\nCLONE\n' > "$clone/f.txt"; git -C "$clone" commit -qam clone-conf
git -C "$clone" fetch -q "$src" HEAD
if git -C "$clone" merge --no-edit FETCH_HEAD; then echo "UNEXPECTED-OK"; else
  git -C "$clone" diff --name-only --diff-filter=U    # expect f.txt (LEFT in place)
  echo "CONFLICT-LEFT-OK"
fi
rm -rf "$base"
```

Expected output includes: `CLEAN-UPDATE-OK`, `UPTODATE-OK`, then `f.txt`, then `CONFLICT-LEFT-OK`.

- [ ] **Step 4: Regenerate + build**

Run:
```
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/App/CloneRunner.swift
git commit -m "feat(app): CloneRunner.updateFromSource — merge source's latest into clone"
```

---

### Task 3: CLI `update-clone` verb (protocol + parser)

**Files:**
- Modify: `Sources/ZettyCore/CLI/ControlProtocol.swift`
- Modify: `Sources/ZettyCore/CLI/ControlCLI.swift`
- Test: `Tests/ZettyCoreTests/ControlProtocolTests.swift` (append; create if absent)

**Interfaces:**
- Produces: `ControlRequest.updateClone(name: String)` (reuses the `.project` CodingKey for the name, like `remove-project`); CLI `update-clone <name>` returning the summary via `.text` or refusal via `.error`.

- [ ] **Step 1: Write the failing round-trip test**

Append to `Tests/ZettyCoreTests/ControlProtocolTests.swift` (create with `import Testing` + `import Foundation` + `@testable import ZettyCore` if absent):

```swift
@Test func updateCloneRequestRoundTrips() throws {
    let line = try ControlWire.encodeLine(.updateClone(name: "zetty/fork-1"))
    let decoded = try ControlWire.decodeRequest(line)
    #expect(decoded == .updateClone(name: "zetty/fork-1"))
}
```

(If `ControlWire.decodeRequest` isn't the entry point the file's other tests use, match theirs — the round-trip is `encodeLine` → decode back to `ControlRequest`.)

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- swift test --filter updateCloneRequestRoundTrips`
Expected: FAIL — `updateClone` is not a member of `ControlRequest`.

- [ ] **Step 3: Add the request case + Codable**

In `Sources/ZettyCore/CLI/ControlProtocol.swift`:

Add to the `ControlRequest` enum (after `.cloneProject`):

```swift
    /// Merge the named clone's SOURCE branch into the clone (update the clone;
    /// leave conflicts in the clone to resolve). Response `.text` with a
    /// summary, or `.error` for a refusal/failure.
    case updateClone(name: String)
```

In `init(from:)`, after the `"clone"` case:

```swift
        case "update-clone":
            self = .updateClone(name: try container.decode(String.self, forKey: .project))
```

In `encode(to:)`, after `.cloneProject`:

```swift
        case .updateClone(let name):
            try container.encode("update-clone", forKey: .command)
            try container.encode(name, forKey: .project)
```

- [ ] **Step 4: Add the CLI parser + help + recognition**

In `Sources/ZettyCore/CLI/ControlCLI.swift`:

Add `"update-clone"` to the `recognizes(...)` array (next to `"clone"`).

Add to the `run(...)` switch (after `"clone"`):

```swift
        case "update-clone":
            return runUpdateClone(arguments)
```

Add the handler after `runClone(...)`:

```swift
    private static func runUpdateClone(_ arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        let name = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return failure("update-clone needs a clone name")
        }
        switch roundTrip(.updateClone(name: name)) {
        case .text(let summary):
            print(summary)
            return 0
        case .error(let message): return failure(message)
        default: return failure("unexpected response")
        }
    }
```

Add to the `usage` string near the `clone` entry:

```
      zetty update-clone <name>               merge the clone's SOURCE branch into
                                              the clone (update it); leaves any
                                              conflicts in the clone to resolve
```

- [ ] **Step 5: Run tests + build**

Run: `mise exec -- swift test --filter updateClone`
Expected: PASS.
Run: `swift build`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/ZettyCore/CLI/ControlProtocol.swift Sources/ZettyCore/CLI/ControlCLI.swift Tests/ZettyCoreTests/ControlProtocolTests.swift
git commit -m "feat(cli): update-clone verb — merge source branch into a clone"
```

---

### Task 4: Route `update-clone` as a slow verb (AppDelegate + TVC helper)

**Files:**
- Modify: `App/Sources/App/AppDelegate.swift`
- Modify: `App/Sources/App/TerminalViewController.swift`

**Interfaces:**
- Consumes: `CloneRunner.updateFromSource(cloneRoot:sourceRoot:)`, `CloneRunner.UpdateOutcome`.
- Produces:
  - `TerminalViewController.UpdateClonePlan` (`.ready(cloneRoot: String, sourceRoot: String)` / `.failed(String)`)
  - `TerminalViewController.planUpdateClone(name: String) -> UpdateClonePlan` (main-thread; resolve by name, require it be a clone with a still-present source).

- [ ] **Step 1: Add the TVC planning helper**

In `App/Sources/App/TerminalViewController.swift`, near `planRemoveProject`/`planClone`, add:

```swift
    enum UpdateClonePlan {
        case ready(cloneRoot: String, sourceRoot: String)
        case failed(String)
    }

    /// Main-thread planning for `update-clone`: resolve the named clone and
    /// confirm it is a clone whose source directory still exists.
    func planUpdateClone(name: String) -> UpdateClonePlan {
        let needle = name.lowercased()
        guard let clone = workspace.projects.first(where: { $0.name.lowercased() == needle }) else {
            return .failed("no project named \"\(name)\"")
        }
        guard let sourceRoot = clone.cloneSource else {
            return .failed("\"\(clone.name)\" is not a clone")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceRoot, isDirectory: &isDir), isDir.boolValue else {
            return .failed("the source directory is gone (\(sourceRoot)) — cannot update")
        }
        return .ready(cloneRoot: clone.rootPath, sourceRoot: sourceRoot)
    }
```

- [ ] **Step 2: Route the verb in `startControlSocket`**

In `App/Sources/App/AppDelegate.swift`, add a case inside the `switch request` in `startControlSocket` (after the `.removeProject` block, before `default`):

```swift
            case .updateClone(let name):
                let planned = DispatchQueue.main.sync { () -> TerminalViewController.UpdateClonePlan in
                    guard let tvc = self.terminalViewController else {
                        return .failed("Zetty is still starting up")
                    }
                    return tvc.planUpdateClone(name: name)
                }
                switch planned {
                case .failed(let message):
                    return .error(message)
                case .ready(let cloneRoot, let sourceRoot):
                    switch CloneRunner.updateFromSource(cloneRoot: cloneRoot, sourceRoot: sourceRoot) {
                    case .updated(let summary):
                        return .text(summary)
                    case .upToDate:
                        return .text("already up to date with the source")
                    case .conflicts(let files):
                        return .error("merge conflicts left in the clone — resolve them there, then "
                            + "commit and PR. Conflicting files:\n" + files.joined(separator: "\n"))
                    case .refused(let message):
                        return .error(message)
                    case .failed(let message):
                        return .error(message)
                    }
                }
```

- [ ] **Step 3: Add `.updateClone` to the main-handler slow-verb guard**

In `App/Sources/App/AppDelegate.swift`, change the slow-verb line in `handleOnMain(...)`:

```swift
        case .capture, .quit, .cloneProject, .removeProject, .updateClone:
            // Slow verbs — handled on the socket queue in startControlSocket.
            return .error("internal: slow verb routed to the main handler")
```

- [ ] **Step 4: Regenerate + build**

Run:
```
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED (the `handleOnMain` switch is exhaustive with the new case).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/App/AppDelegate.swift App/Sources/App/TerminalViewController.swift
git commit -m "feat(app): route update-clone as a slow control verb"
```

---

### Task 5: Instruction UI — banner button + sync-guide popover

**Files:**
- Modify: `App/Sources/App/CloneWarningBanner.swift`
- Create: `App/Sources/App/CloneMergeGuideView.swift`
- Modify: `App/Sources/App/TerminalViewController.swift` (banner construction, ~line 2907)

**Interfaces:**
- Consumes: `CloneSupport.syncGuide(...)`, `ZTheme`.
- Produces:
  - `CloneWarningBanner.init(branch: String? = nil, clonePath: String? = nil, sourcePath: String? = nil)` — shows the button only when all three are present (git clone).
  - `CloneMergeGuideView(guide: CloneSupport.SyncGuide)` (`NSViewController`).

- [ ] **Step 1: Create the popover content view controller**

Create `App/Sources/App/CloneMergeGuideView.swift`:

```swift
import AppKit
import ZettyCore

/// Popover body for the clone banner's "How do I merge this back?" affordance —
/// the feature-branch flow with this clone's real branch and paths filled in:
/// update from source → PR (primary) → no-origin local merge fallback.
/// Text only; the automated action lives in the context menu.
@MainActor
final class CloneMergeGuideView: NSViewController {

    private let guide: CloneSupport.SyncGuide

    init(guide: CloneSupport.SyncGuide) {
        self.guide = guide
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = ZTheme.current.bg1Color.cgColor

        let stack = NSStackView(views: [
            Self.body("Your clone's work lives on its own branch, “\(guide.branch)”. "
                + "Update it from the source, resolve conflicts here, then open a PR — "
                + "don't push the clone's main."),
            Self.heading("1 · Update from source (fix conflicts here)"),
            Self.steps([guide.updateStep]),
            Self.heading("2 · Push and open a PR"),
            Self.steps(guide.prSteps),
            Self.heading("No origin? Merge locally into the source instead"),
            Self.steps(guide.localFallbackSteps),
            Self.body("Tip: “Update from Source” (right-click the clone) does step 1 "
                + "for you when the clone is clean."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 460),
        ])
        self.view = root
    }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = ZTheme.current.fgColor
        return label
    }

    private static func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = ZTheme.current.fg2Color
        label.preferredMaxLayoutWidth = 432
        return label
    }

    /// Shell commands → mono font (terminal-adjacent) on the elevated surface.
    private static func steps(_ lines: [String]) -> NSView {
        let stack = NSStackView(views: lines.map { line in
            let label = NSTextField(wrappingLabelWithString: line)
            label.font = ZTheme.monoFont(size: 12)
            label.textColor = ZTheme.current.fgColor
            label.preferredMaxLayoutWidth = 412
            return label
        })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.wantsLayer = true
        stack.layer?.backgroundColor = ZTheme.current.bg2Color.cgColor
        stack.layer?.cornerRadius = 5
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        return stack
    }
}
```

- [ ] **Step 2: Add the button + popover to the banner**

Rewrite `App/Sources/App/CloneWarningBanner.swift`:

```swift
import AppKit
import ZettyCore

@MainActor
final class CloneWarningBanner: NSView {

    static let height: CGFloat = 26

    private let branch: String?
    private let clonePath: String?
    private let sourcePath: String?
    private var popover: NSPopover?

    /// `branch` nil → the clone is not a git repo; the merge affordance is hidden.
    init(branch: String? = nil, clonePath: String? = nil, sourcePath: String? = nil) {
        self.branch = branch
        self.clonePath = clonePath
        self.sourcePath = sourcePath
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = ZTheme.current.bg2Color.cgColor

        let accentBar = NSView()
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = ZTheme.current.yellowColor.cgColor
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)

        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = ZTheme.current.borderColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: "Clone warning")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        icon.contentTintColor = ZTheme.current.yellowColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithAttributedString: Self.message())
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        let arranged: [NSView]
        if branch != nil, clonePath != nil, sourcePath != nil {
            let button = NSButton(title: "How do I merge this back?", target: self,
                                  action: #selector(showGuide(_:)))
            button.isBordered = false
            button.attributedTitle = NSAttributedString(
                string: "How do I merge this back?",
                attributes: [.font: ZTheme.monoFont(size: 12),
                             .foregroundColor: ZTheme.current.accentColor])
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.translatesAutoresizingMaskIntoConstraints = false
            arranged = [icon, label, button]
        } else {
            arranged = [icon, label]
        }

        let stack = NSStackView(views: arranged)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 2),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    @objc private func showGuide(_ sender: NSButton) {
        guard let branch, let clonePath, let sourcePath else { return }
        let guide = CloneSupport.syncGuide(
            branch: branch, clonePath: clonePath, sourcePath: sourcePath, defaultBranch: "main")
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = CloneMergeGuideView(guide: guide)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        self.popover = popover
    }

    private static func message() -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: "Clone (copy-on-write). ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: ZTheme.current.fgColor,
            ])
        result.append(NSAttributedString(
            string: "Commit and push to origin, or merge back into the source branch — uncommitted changes are lost when this clone is removed.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: ZTheme.current.fg2Color,
            ]))
        return result
    }
}
```

- [ ] **Step 3: Pass clone context at the banner construction site**

In `App/Sources/App/TerminalViewController.swift`, replace `let banner = CloneWarningBanner()` (~line 2908) with:

```swift
            let clone = workspace.activeProject
            // Git clones expose the merge-guide button; non-git clones don't.
            let cloneGitDir = (clone.rootPath as NSString).appendingPathComponent(".git")
            let isGitClone = FileManager.default.fileExists(atPath: cloneGitDir)
            let branch = isGitClone
                ? (clone.name.split(separator: "/").last.map(String.init) ?? clone.name)
                : nil
            let banner = CloneWarningBanner(
                branch: branch,
                clonePath: isGitClone ? clone.rootPath : nil,
                sourcePath: isGitClone ? clone.cloneSource : nil)
```

- [ ] **Step 4: Regenerate (new file) + build**

Run:
```
mise exec -- tuist clean
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/App/CloneWarningBanner.swift App/Sources/App/CloneMergeGuideView.swift App/Sources/App/TerminalViewController.swift
git commit -m "feat(app): clone banner sync-guide popover (git clones only)"
```

---

### Task 6: GUI "Update from Source" action (context menu)

**Files:**
- Modify: `App/Sources/App/SidebarView.swift`
- Modify: `App/Sources/App/TerminalViewController.swift`

**Interfaces:**
- Consumes: `CloneRunner.updateFromSource(...)`, `CloneRunner.UpdateOutcome`.
- Produces:
  - `SidebarView.onUpdateClone: ((Int) -> Void)?`
  - "Update from Source" menu item, git clone rows only.
  - `TerminalViewController.confirmUpdateClone(at index: Int)` — confirm → off-main update → result alert.

- [ ] **Step 1: Add the callback + menu item**

In `App/Sources/App/SidebarView.swift`, add near `onCloneProject` (~line 123):

```swift
    var onUpdateClone: ((Int) -> Void)?
```

Add the click handler near `cloneProjectMenuClicked` (~line 616):

```swift
    @objc private func updateCloneMenuClicked(_ sender: NSMenuItem) {
        let projectIndex = sender.tag
        guard projects.indices.contains(projectIndex) else { return }
        onUpdateClone?(projectIndex)
    }
```

In `menuNeedsUpdate(_:)`, inside `if !isScratch {`, after the `Clone Project…` block, add:

```swift
            if projects[p].isClone {
                let update = NSMenuItem(title: "Update from Source",
                                        action: #selector(updateCloneMenuClicked(_:)),
                                        keyEquivalent: "")
                update.target = self
                update.tag = p
                menu.addItem(update)
            }
```

- [ ] **Step 2: Wire the callback in TVC**

In `App/Sources/App/TerminalViewController.swift`, after the `sidebar.onCloneProject = ...` block (~line 537), add:

```swift
        sidebar.onUpdateClone = { [weak self] index in
            self?.confirmUpdateClone(at: index)
        }
```

- [ ] **Step 3: Implement `confirmUpdateClone`**

In `App/Sources/App/TerminalViewController.swift`, in the Remove Clone section, add:

```swift
    // MARK: - Update Clone from Source

    /// Confirms, then merges the source's latest branch into the clone
    /// (leave-conflicts, off-main). Nothing is deleted; conflicts are left in
    /// the clone to resolve.
    private func confirmUpdateClone(at index: Int) {
        guard workspace.projects.indices.contains(index) else { return }
        let clone = workspace.projects[index]
        guard let sourceRoot = clone.cloneSource else { return }
        let cloneRoot = clone.rootPath
        let cloneName = clone.name

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update “\(cloneName)” from its source?"
        alert.informativeText = "Merges the source's latest branch into this clone so it's "
            + "current. Any conflicts are left in the clone for you to resolve, then commit and "
            + "open a PR. Commit your clone changes first — a dirty clone is refused."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = CloneRunner.updateFromSource(cloneRoot: cloneRoot, sourceRoot: sourceRoot)
                DispatchQueue.main.async { self.presentUpdateOutcome(outcome, cloneName: cloneName) }
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: run)
        } else {
            run(alert.runModal())
        }
    }

    private func presentUpdateOutcome(_ outcome: CloneRunner.UpdateOutcome, cloneName: String) {
        let alert = NSAlert()
        switch outcome {
        case .updated(let summary):
            alert.alertStyle = .informational
            alert.messageText = "Updated “\(cloneName)” from its source"
            alert.informativeText = summary
        case .upToDate:
            alert.alertStyle = .informational
            alert.messageText = "Already up to date"
            alert.informativeText = "“\(cloneName)” already contains the source's latest."
        case .conflicts(let files):
            alert.alertStyle = .warning
            alert.messageText = "Merge conflicts to resolve"
            alert.informativeText = "The merge is in progress in the clone. Resolve these files "
                + "there, then commit and open a PR:\n" + files.joined(separator: "\n")
        case .refused(let message):
            alert.alertStyle = .warning
            alert.messageText = "Nothing updated"
            alert.informativeText = message
        case .failed(let message):
            alert.alertStyle = .critical
            alert.messageText = "Update failed"
            alert.informativeText = message
        }
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }
```

- [ ] **Step 4: Regenerate + build**

Run:
```
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual verification (user-side per TCC constraint)**

Via CLI (headless): make a git project, `zetty clone --name fork-1`, advance the source repo with a commit, then `zetty update-clone <source>/fork-1` and confirm the summary prints and the source commit is now in the clone (`git -C <clonePath> log`). Force a conflict and confirm `update-clone` reports the conflicting file and leaves the clone mid-merge. GUI menu item + popover confirmed visually by the user.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/App/SidebarView.swift App/Sources/App/TerminalViewController.swift
git commit -m "feat(app): Update from Source clone context-menu action"
```

---

### Task 7: Documentation (README + CLAUDE.md/AGENTS.md)

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: README — clone section**

In `README.md`, in the Project clones section, add:

```markdown
#### Bringing clone work back

A clone's `.git` is a full copy of the source, so it carries the source's
`main` and the same `origin`. Your clone's work lives on its own branch
`<name>` — **don't push the clone's `main`** (that just creates two divergent
`main`s). The feature-branch flow:

1. **Update from source.** Merge the source's latest branch into the clone so
   it's current, resolving any conflicts *in the clone*. Right-click the clone →
   *Update from Source*, or run `zetty update-clone <name>`. It refuses a dirty
   clone (commit first) and, on conflict, leaves the merge in progress in the
   clone for you to resolve.
2. **Push and open a PR** (primary): `git push -u origin <name>`, then open a
   pull request against the source's default branch.
3. **No origin? Merge locally into the source instead:** in the source repo,
   `git fetch <clonePath> <name>` then `git switch main` and `git merge <name>`.

The clone banner's **"How do I merge this back?"** button shows these steps with
your clone's real branch and paths filled in (git clones only).
```

Also add `update-clone` to the Control CLI command list.

- [ ] **Step 2: CLAUDE.md + AGENTS.md — clone section note**

Append the SAME paragraph to BOTH files' Project clones section: pure
`CloneSupport.updateReadiness` / `syncGuide` + arg builders; app-layer
`CloneRunner.updateFromSource` (source → clone, fetch source `HEAD` into
`FETCH_HEAD`, **leave-conflicts** in the clone); `CloneWarningBanner` "How do I
merge this back?" popover (`CloneMergeGuideView`, git clones only); the "Update
from Source" context-menu action; CLI `update-clone` routed as a slow verb.

- [ ] **Step 3: Verify parity**

Run: `diff CLAUDE.md AGENTS.md`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md AGENTS.md
git commit -m "docs: document clone Update from Source + merge-back flow"
```

---

## Self-Review

**Spec coverage:**
- Feature-branch flow instruction (banner popover + README) → Tasks 5, 7. ✅
- Automated **Update from Source** (source → clone), GUI + CLI → Tasks 2, 3, 4, 6. ✅
- Leave-conflicts-in-the-clone policy → Task 2, surfaced in Tasks 4 & 6. ✅
- PR primary + no-origin local fallback documented → Tasks 5, 7. ✅
- Non-git clone handling → Task 1 (`.notGit`), Task 2 (refusal), Task 5 (button hidden). ✅
- Clone-on-fallback-`main` robustness (fetch source `HEAD`) → Tasks 1–2. ✅
- Docs + CLAUDE/AGENTS parity → Task 7. ✅

**Placeholder scan:** no TBD/TODO; every code step shows full code; commands have expected output. ✅

**Type consistency:** `UpdateReadiness` (`.notGit`/`.cloneDirty`/`.ready`) identical in Tasks 1–2; `UpdateOutcome` (`.updated`/`.upToDate`/`.conflicts`/`.refused`/`.failed`) identical in Tasks 2, 4, 6; `SyncGuide` fields (`branch`/`updateStep`/`prSteps`/`localFallbackSteps`) identical in Tasks 1, 5; `planUpdateClone`/`UpdateClonePlan` identical in Task 4; `ControlRequest.updateClone(name:)` identical in Tasks 3, 4. ✅

**Note on TDD:** Task 1 (pure) is real red→green TDD; Task 3 protocol round-trip is unit-tested. Tasks 2/4/6 are AppKit + git process IO where GUI verification is TCC-denied (see memory) — verified via a headless git integration script (Task 2 Step 3) and CLI round-trip (Task 6 Step 5).
