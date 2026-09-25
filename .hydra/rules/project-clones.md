---
paths:
    - "Sources/ZettyCore/Clone/**"
    - "App/Sources/App/CloneRunner.swift"
    - "App/Sources/App/CloneWarningBanner.swift"
    - "App/Sources/App/CloneMergeGuideView.swift"
    - "App/Sources/App/FileCopyBackRunner.swift"
    - "App/Sources/App/FileCopyBackSheet.swift"
commands:
    - "zetty clone"
    - "zetty update-clone"
    - "zetty remove-project"
triggers:
    - "changing project clones, merge-back, or clone removal"
---

# Project clones

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

An instant APFS copy-on-write fork of a project — untracked files, `.env`,
`node_modules` all included — checked out onto its own git branch. Persisted
as `cloneSource: String?` (the source's canonical rootPath, nil for ordinary
projects) on `Project`/`ProjectRuntime`, decoded tolerantly like `isHome` so
old `workspace.json` files load unchanged.

The split mirrors `GitStatus`: pure planning in `CloneSupport`
(`ZettyCore/Clone/`) — `ClonePlan` (target path under
`~/.zetty/clones/<slug(source)>-<name>`, branch `<name>`, display name
`<source>/<name>`), name validation/slugging, git argument builders, and the
removal classifier (`CloneWorkState`: clean / unfetched / dirty) — versus
process IO in the app-layer `CloneRunner` (`cp -Rc` with a `cp -R` fallback
for non-APFS volumes, `git switch -c`, fetch-back, branch/dirty probes,
guarded delete).

`clone` is a **slow verb**: `AppDelegate.startControlSocket` special-cases it
(alongside `capture`/`quit`) to plan on main (workspace state), copy on the
socket queue (a non-APFS fallback `cp -R` can be slow), then register on main
— `handleOnMain`'s default switch deliberately errors if one of these three
lands there ("internal: slow verb routed to the main handler").

Removal (`CloneRunner.fetchBack`, wired from both `zetty remove-project
--fetch` and the GUI's Remove Clone… dialog) runs `git fetch <clonePath>
<branch>:<branch>` in the SOURCE repo; a failure aborts before anything is
deleted — nothing is lost on a bad fetch. Deletion itself is guarded by
`CloneSupport.isSafeToDelete` — strictly inside `~/.zetty/clones/`, never the
root itself, no `..` traversal.

Clones inherit the source project's settings and offer no Project Settings…
of their own (the sidebar context menu hides it — a clone-owned settings
file would break inheritance). `AppDelegate.resolvedSettings(for:)` falls
back to the source's settings with `name` and `icon` cleared (an inherited
name would rename the clone to match its source; an inherited icon would
suppress the fork glyph that marks the row as a clone). A clone-keyed
settings entry, if one ever exists on disk, still wins wholesale.

The clone sheet (`promptCloneProject`) shows an **Open with** picker when the
SOURCE project has agents set (`agentsProvider`, Project Settings → Agents):
each enabled agent plus "Standard session", defaulting to the first agent.
The pick's command threads through `registerClone(plan:outcome:focus:startupCommand:)`
into `pendingStartupCommands` BEFORE the pane spawns — the same injection
path as the new-pane agent chooser. CLI `zetty clone` never injects a
command.

Limits: no clones of clones (`cloneSource == nil` required on the source),
Home/Scratch can't be cloned, and neither can any project whose rootPath IS
the home directory or an ancestor of it (`CloneSupport.isCloneableSource` —
legacy pre-Home workspaces have ordinary projects rooted at ~, and cloning ~
drags in the whole TCC-protected account). `cp` copy noise from sockets/fifos
is tolerated (`copyErrorsAreTolerable`) — without that, one stray `.sock`
file forces a pointless full-copy fallback; real failures surface truncated
via `summarizeCopyErrors`. `WorkspaceModel.regroup()` slots each clone row
immediately after its source in sidebar/CLI order; an orphaned clone (source
removed) falls back to an ordinary position.

The copy runs off-main (GUI: a background queue; CLI: the socket queue), so
the UI never blocks. While it runs, a transient "Cloning…" spinner row is
spliced under the source (`TerminalViewController.pendingClones` +
`beginPendingClone`/`endPendingClone`; rendered via `SidebarProject.isPendingClone`
as a non-interactive `NSProgressIndicator` row — not selectable, no menu, not
draggable). It clears when the copy finishes; the real clone row then arrives
via `registerClone`.

When the active project is a clone, `rebuildSurfaceNodeView()` slots a
`CloneWarningBanner` (App layer) below the tab bar — a persistent yellow-accent
caution strip (semantic `yellow` = attention) reminding that the CoW copy is
disposable: uncommitted changes are lost on removal, so commit + push to origin
or merge back into the source. It becomes the `topGuide` for the content, so it
shows above the terminal AND the hibernation placeholder; it's recreated per
rebuild, so it appears/disappears automatically as the active project switches.

Clones can be brought back in sync with their source without leaving the
clone: pure readiness classification and copy-paste guide text live in
`CloneSupport` (`updateReadiness` — `.notGit`/`.cloneDirty`/`.ready` — and
`syncGuide`, plus the fetch/merge/conflict-files git arg builders); the
app-layer `CloneRunner.updateFromSource` runs source → clone (`git fetch
<source> HEAD` into `FETCH_HEAD`, then `git merge --no-edit FETCH_HEAD`) and
**leaves conflicts in the clone** to resolve rather than aborting — nothing is
lost, the user commits and PRs from there. The `CloneWarningBanner`'s "How do I
merge this back?" button (git clones only — hidden when `clonePath`/`sourcePath`
are nil) opens an `NSPopover` hosting `CloneMergeGuideView` with the update /
PR / no-origin-local-merge steps filled in with the clone's real branch and
paths, plus a pointer to the automated chooser below.

The sidebar context menu's **"Merge to Source…"** action
(`confirmMergeToSource`) probes the source's git/remote state off-main
(`CloneRunner.isGitWorkTree`/`hasRemote`) into the pure
`CloneSupport.mergeToSourceOptions` (`MergeToSourceOptions.canMergeUpdates`/
`canPushToBranch` — the latter requires a remote), then shows an alert
offering **Merge updates** (`CloneRunner.mergeUpdates` — reuses
`updateFromSource` for the sync step, then fetches the clone into the SOURCE
and merges there locally; refuses on a dirty source, and aborts cleanly
leaving the source untouched if that merge conflicts) and, when available,
**Push to branch** (`CloneRunner.pushBranch` — same sync step, then `git push
-u origin <branch>` from the clone for a PR). A non-git source instead opens the **file
copy-back diff modal**: pure `FileCopyBack` (ZettyCore) parses `git diff
--no-index --no-renames --name-status -z <source> <clone>` into added/modified
`FileChange`s and computes Keep-Both names (`name 2.ext`); the app-layer
`FileCopyBackRunner` runs that diff plus a per-file `git diff --no-index`
content preview and, on confirm, copies chosen files into the source
(overwrites go through a temp file + `replaceItemAt` so the original survives
a failed copy — nothing is ever deleted); `FileCopyBackSheet` is the modal
itself, listing each changed/new file with its line-diff preview and a
per-file **Replace**/**Keep Both** choice, launched from the non-git branch of
`presentMergeToSourceChooser`. The CLI
`update-clone <name>` verb is UNCHANGED: it still drives only the shared sync
step (`CloneRunner.updateFromSource`) and is routed as a **slow verb**
alongside `clone`/`capture`/`quit`/`removeProject` (plan on main via
`TerminalViewController.planUpdateClone`, merge off the socket queue, outcome
text/error returned to the CLI) — the GUI's Merge updates/Push to branch
strategies are not exposed to the CLI in Phase 1.
