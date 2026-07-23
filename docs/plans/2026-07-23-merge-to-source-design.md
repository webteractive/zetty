# Clone → Source integration — "Merge to Source…"

**Date:** 2026-07-23
**Status:** Approved design (supersedes the update-from-source-only shape in
`2026-07-20-clone-merge-back-design.md`)

## Problem

Today a clone offers **Update from Source** (menu + `zetty update-clone`),
which only does the first half of the story: it merges the source's latest
branch INTO the clone. Getting the clone's finished work *back to the source*
is still manual. We want to give the user an explicit, safe choice of how their
work lands back on the source, adapted to what the source actually is (a git
repo with a remote, a git repo without one, or a non-git directory).

## Model — one adaptive entry point, three source cases

A single clone-row context-menu item **"Merge to Source…"** (replaces "Update
from Source") opens a dialog whose options depend on the source. Every git path
begins with the existing **sync step** (merge the source's latest into the
clone, resolve conflicts in the clone), so the final landing is clean.

| Source | Options offered |
|---|---|
| **Git + has remote** | **Merge updates** (sync, then merge clone→source locally) · **Push to branch** (sync, then push the clone's branch to the remote for a PR) |
| **Git, no remote** | **Merge updates** only (Push to branch shown disabled, with a note) |
| **Not a git repo** | **File copy-back** via a diff modal (Phase 2) |

## Flow (git cases)

Preconditions:
1. Clone and source are both git work trees (else → non-git path / Phase-2).
2. Clone working tree is clean (committed). Dirty → refuse: "commit your clone
   work first."

**Sync step (shared, reuses `CloneRunner.updateFromSource`):** merge the
source's current branch into the clone (`fetch <source> HEAD` → `merge
FETCH_HEAD`). Outcomes:
- up-to-date or clean merge → proceed to the chosen strategy;
- **conflicts** → left in the clone (existing leave-conflicts policy); stop and
  tell the user to resolve + commit in the clone, then re-invoke. "Merge to
  Source…" is therefore resumable, not atomic-through-a-conflict.

**Merge updates (clone → source, local):** in the SOURCE, refuse if its working
tree is dirty; else `fetch <clonePath> HEAD` → `merge --no-edit FETCH_HEAD`.
Because the sync step already pulled the source's tip into the clone, the
source's branch tip is an ancestor of the clone's tip, so this is a
fast-forward / clean merge. Abort-on-conflict in the source (never leave the
source mid-merge — the source is the user's real project, not disposable).
No remote required.

**Push to branch (clone → remote):** `git -C <clone> push -u origin <branch>`;
report success + "open a PR against <defaultBranch>". We do NOT create the PR
(no host API). Offered only when the clone has a remote (`git remote` non-empty).

## Non-git case (Phase 2) — diff modal + file copy-back

No git to merge, so getting work back is a file operation. Use the git binary
that is already present as a plain diff engine on arbitrary paths:
`git diff --no-index <source> <clone>` works OUTSIDE any repo.

- `git diff --no-index --name-status <source> <clone>` → the changed-file list
  (added / modified / deleted).
- per file, `git diff --no-index <source-file> <clone-file>` → the line-level
  diff to render.

Modal:
- Left: changed-file list (added / modified / deleted), each with an
  include checkbox (all checked by default) and a per-file **Replace / Keep
  Both** choice.
- Right: the selected file's line-level diff (clone vs source).
- **Replace** overwrites the source's file with the clone's; **Keep Both**
  writes the clone's version as `name 2.ext`, never destroying the source's
  copy. Source-only files (absent from the clone) are left untouched — a copy
  back never deletes. A summary confirm precedes any write.

(The macOS Finder duplication dialog is the conceptual reference for
Replace/Keep-Both, not a UI to reproduce pixel-for-pixel.)

## Phasing

- **Phase 1 (this plan):** git cases — the "Merge to Source…" chooser, **Merge
  updates**, and **Push to branch**, reusing `updateFromSource` /
  `currentBranch` and the existing pure arg-builder pattern. Ships the core value.
- **Phase 2 (separate plan):** the non-git diff modal + file copy-back.

## Architecture (Phase 1)

- **Pure (`ZettyCore/Clone/CloneSupport.swift`):** new git arg builders —
  `hasRemoteArgs` (`["remote"]`), `mergeBackFetchArgs(clonePath:)` (`["fetch",
  clonePath, "HEAD"]`), `mergeBackMergeArgs` (`["merge", "--no-edit",
  "FETCH_HEAD"]`), `mergeAbortArgs` (`["merge", "--abort"]`), `pushBranchArgs(branch:)`
  (`["push", "-u", "origin", branch]`). A pure `MergeToSourceOptions` descriptor
  (which strategies are available given `isGit`/`hasRemote`) so the dialog logic
  is testable.
- **App IO (`App/Sources/App/CloneRunner.swift`):** `hasRemote(in:)`,
  `mergeUpdates(cloneRoot:sourceRoot:) -> MergeBackOutcome` (sync-then-merge-back,
  abort-on-conflict in source), `pushBranch(cloneRoot:) -> PushOutcome`
  (sync is invoked first by the caller). Reuse `updateFromSource` for the shared
  sync step and surface its conflict outcome to the caller.
- **UI (`App/Sources/App/…`):** rename the context-menu item to "Merge to
  Source…"; a chooser sheet (`MergeToSourceSheet` or an NSAlert with buttons)
  presenting the available strategies; result alerts per outcome. `confirmUpdateClone`
  becomes `confirmMergeToSource`.
- **CLI:** `zetty update-clone` stays (sync-only, scripting). Phase-1 strategies
  are GUI-first; optional `--merge`/`--push` flags deferred.

## Testing

- Pure: arg builders + `MergeToSourceOptions` availability matrix (git+remote /
  git-no-remote / non-git) unit-tested.
- App IO: headless git integration script exercising sync→merge-back (clean +
  fast-forward), sync-leaves-conflict (stop), source-dirty refusal, and
  push-to-branch against a throwaway bare remote.
- GUI chooser/alerts verified by the user (TCC-denied headless).

## Edge cases

- Sync produces conflicts → stop, resolve-in-clone-then-retry (resumable).
- Source dirty during Merge updates → refuse (don't touch a dirty source).
- Merge-back somehow non-fast-forward (source advanced mid-flight) and conflicts
  → abort in source, report; nothing left half-merged.
- No remote → Push to branch disabled with a note; Merge updates still offered.
- Non-git source → Phase 2 (until then, the dialog says file copy-back is coming
  / falls back to the existing behavior).
