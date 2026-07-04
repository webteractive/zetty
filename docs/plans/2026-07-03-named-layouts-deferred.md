# Named layouts & workspaces — deferred (2026-07-03)

**Status: superseded (2026-07-04)** by
[`2026-07-04-layout-templates-design.md`](2026-07-04-layout-templates-design.md),
which builds exactly the "thin slice" identified below. The revisit trigger
fired. This note is kept for the rationale.

**Original status: tabled.** This was the last unbuilt PRD Phase 2 item
(`docs/plans/2026-06-25-quertty-prd.md` §9). We decided not to build it now.
This note records why, and what would change our mind.

## What the PRD item meant

Multiple named snapshots of a tab/split arrangement, managed deliberately —
tmuxinator / iTerm window arrangements: save the current arrangement as `dev`,
apply it on demand (palette / prefix binding / `zetty layout apply dev`),
list/rename/delete. Distinct from today's `workspace.json`, which is a single
implicit snapshot auto-saved continuously and restored only on relaunch.

## Why it's deferred

The two classic justifications for this feature class are already covered:

1. **Recreating your setup after restart/detach** — solved harder and better
   by the existing auto-restore (`WorkspaceStore` → `workspace.json`) plus
   `preserve-sessions` (zmx), which keeps the *processes* alive across
   quit/relaunch, not just the geometry.
2. **Scripted setup** — already possible via the control CLI: a five-line
   script of `zetty new-tab` / `zetty split` / `zetty send` builds any
   arrangement (agent pane + shell + logs, cd'd correctly, commands running).
   The full feature would be sugar over an existing primitive.

What remains is one narrower, real use case: **the repeating ritual** — every
new project starting with the same split-and-launch ceremony.

## The thin slice worth building (if ever)

Not a full named-layout catalog with save/list/rename/delete UI. Instead:
**one default layout template, per project or global, applied on project
open** — panes with cwd and an optional startup command each. That captures
most of the value at a fraction of the cost. The `Workspace`/`PaneTree`
Codable models and the relaunch-restore path would be reused; the new work is
an "apply to live window" path that rebuilds tabs/splits without relaunch,
plus a small UX surface.

## Revisit trigger

Dogfooding evidence: catching ourselves re-running the same split-and-launch
sequence across projects. Until then, a shell script over the CLI *is* the
feature. If the trigger fires, build the template slice first and only grow
it into a named catalog if templates prove insufficient.
