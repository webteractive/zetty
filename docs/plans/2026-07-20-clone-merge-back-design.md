# Clone merge-back — instruction + "Update from Source" action

**Date:** 2026-07-20
**Status:** Approved design (revised — feature-branch flow)

## Problem

A project clone is an APFS copy-on-write fork whose `.git` is a full copy of the
source — it carries the source's `main` (and the same `origin` config), and
Zetty puts the clone's work on its own branch `<name>` via `git switch -c
<name>`. Users trying to get clone work back into the source hit two traps:

1. They commit onto `main` in the clone and try to push — producing two
   divergent `main`s (and worse, the clone shares the source's `origin`).
2. When the repo has **no origin remote**, "commit and push" has nowhere to go.

The current `CloneWarningBanner` states the *what* ("commit and push, or merge
back into the source branch") but not the *how*, and there is no in-app help
for the actual integration workflow.

## Intended workflow (feature-branch flow)

For a git clone, the safe path is:

1. Work on the clone's own branch `<name>`.
2. **Update from source:** merge the source's latest branch into the clone's
   branch, so the clone is current — **resolve any conflicts here, in the
   clone** (where your work and full context live).
3. **PR:** push the clone's branch (`git push -u origin <name>`) and open a pull
   request against the source's default branch. *(Primary integration path.)*
4. **No origin (fallback):** merge the clone's branch into the source locally.
   Documented, not automated.

## Goals

- Teach this workflow in-app (banner popover) and in docs.
- Provide one safe automated action, **Update from Source** (source → clone),
  that fetches the source's branch and merges it into the clone, leaving any
  conflicts in the clone for the user to resolve.
- Handle non-git clones cleanly (nothing to update/merge).

## Non-goals

- Automating the PR (that's the user's `git push` + host UI).
- Automating the no-origin local merge-into-source (documented fallback only).
- Removing the clone (Update from Source never deletes anything).

## Design

### 1. Pure logic — `Sources/ZettyCore/Clone/CloneSupport.swift` (unit-tested)

- **Readiness classifier** `UpdateReadiness`:
  - `.notGit` — clone or source is not a git work tree
  - `.cloneDirty` — clone has uncommitted changes (commit before pulling source in)
  - `.ready`
  `updateReadiness(isCloneGitWorkTree:isSourceGitWorkTree:cloneDirty:)`.
- **Git arg builders** (run via `git -C <dir>`):
  - `isGitWorkTreeArgs` → `["rev-parse", "--is-inside-work-tree"]`
  - `cloneStatusArgs` → `["status", "--porcelain"]`
  - `updateFetchArgs(sourcePath:)` → `["fetch", sourcePath, "HEAD"]` — fetch the
    **source's current branch tip** into `FETCH_HEAD`.
  - `alreadyCurrentArgs` → `["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"]`
    (exit 0 ⇒ clone already contains the source tip ⇒ up to date)
  - `updateMergeArgs` → `["merge", "--no-edit", "FETCH_HEAD"]`
  - `conflictFilesArgs` → `["diff", "--name-only", "--diff-filter=U"]`
- **Instruction text** `SyncGuide` +
  `syncGuide(branch:clonePath:sourcePath:defaultBranch:)`:
  - `updateStep` — merge source's latest into the clone (or "use Update from Source")
  - `prSteps` — `git push -u origin <branch>`, open a PR against `<defaultBranch>`
  - `localFallbackSteps` — no-origin: `cd <sourcePath>`, `git fetch <clonePath>
    <branch>`, `git switch <defaultBranch>`, `git merge <branch>`

### 2. Process IO — `App/Sources/App/CloneRunner.swift` (off-main)

`updateFromSource(cloneRoot:sourceRoot:) -> UpdateOutcome`:
1. Probe clone + source are git work trees → `.refused(.notGit)`.
2. Probe clone `status --porcelain`; refuse if dirty (`.cloneDirty`).
3. `git -C clone fetch <sourceRoot> HEAD` → `.failed` on error.
4. `git -C clone merge-base --is-ancestor FETCH_HEAD HEAD` exit 0 → `.upToDate`.
5. `git -C clone merge --no-edit FETCH_HEAD`:
   - status 0 → `.updated(summary)`
   - else → list conflict files; **leave the merge in progress in the clone**
     (do NOT abort) → `.conflicts(files)`. This is the intended "fix conflict
     in the clone" step. If git failed without conflict files, abort and
     `.failed`.

`UpdateOutcome`: `.updated(summary:)` · `.upToDate` · `.conflicts(files:)` ·
`.refused(String)` · `.failed(String)`.

**Conflict policy — leave-conflicts (clone side).** The opposite of a
merge-into-source: because we merge INTO the disposable clone, leaving conflict
markers there for the user to resolve is exactly the workflow. Standard `git
merge` behavior; the clone is the user's working branch.

### 3. Instruction UI — `App/Sources/App/CloneWarningBanner.swift`

- Trailing accent-text button **"How do I merge this back?"** (`ZTheme` accent,
  mono font). Opens an `NSPopover` (IconPicker pattern) hosting
  `CloneMergeGuideView`, filled with this clone's real branch + paths from
  `syncGuide(...)`: **1) update from source & fix conflicts, 2) push + PR, 3)
  no-origin local fallback**.
- **Non-git clone:** hide the button (nothing to merge).

### 4. Automated action surfaces

- **GUI:** clone-row context menu **"Update from Source"**. Confirmation →
  off-main `updateFromSource` → result alert (updated / already current /
  conflicts-left-in-clone / refused). Hidden for non-git clones.
- **CLI:** `zetty update-clone <name>` as a **slow verb** (routed in
  `startControlSocket` like `clone`/`removeProject`; `handleOnMain` errors if it
  lands there). New `ControlCommand.updateClone(name:)`; help + parse in
  `ControlCLI`. Returns the summary via `.text`, refusals/conflicts via
  `.error`.
- **Guards:** clone must be a git work tree with a clean working tree; the
  source directory must still exist.

### 5. Docs

- `README.md` clone section gains **"Bringing clone work back"**: the
  feature-branch flow (update from source → fix conflicts → PR), the **Update
  from Source** action + `zetty update-clone`, and the no-origin local-merge
  fallback.
- Mirror a clone-section note into `CLAUDE.md` / `AGENTS.md` byte-identically.

## Testing

- `CloneSupportTests`: arg builders, `UpdateReadiness` matrix (incl. `.notGit`,
  `.cloneDirty`), `syncGuide` assembly.
- App-layer `updateFromSource` verified via a headless git integration script
  (clean update, up-to-date, conflict-left-in-clone) — no GUI/TCC needed.
- CLI round-trip unit-tested; GUI menu/popover verified user-side per the
  TCC-denied constraint.

## Edge cases

- **Non-git clone (source never git, or `git switch -c` failed):** button
  hidden; action/CLI refuse with a clear message.
- **Clone on a fallback `main` (branch setup failed):** still updates — we merge
  the source's HEAD into whatever the clone has checked out.
- **Source advanced, clone behind:** the common case — fast-forward or merge
  commit into the clone.
- **Conflicts:** left in the clone for the user to resolve, then commit + PR.
- **No origin:** documented local merge-into-source fallback (manual).
