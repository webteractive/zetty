# Project Layout Templates — Design

**Date:** 2026-07-04 · **Status:** Shipped (consolidated into per-project settings v2 — template lives in `.zetty/project.json`; on-demand apply/save via the Project Settings sheet rather than palette/prefix bindings, which remain a possible follow-up) · **Supersedes:**
[`2026-07-03-named-layouts-deferred.md`](2026-07-03-named-layouts-deferred.md)

When a project opens, optionally rebuild a saved tab/split arrangement where
each pane has a cwd (relative to the project root) and an optional startup
command — e.g. "3 panes, each running `claude` in a different subdir." This is
exactly the **thin slice** the deferred note pointed at: one default template
per project (or global), applied on project open, not a full named-layout
catalog. The revisit trigger for that note ("catching ourselves re-running the
same split-and-launch ceremony") is now the explicit ask.

## Goals

- Define a **layout template**: an ordered set of tabs, each a split tree of
  panes; each pane carries a working directory (relative to the project root)
  and an optional startup command.
- Apply a template **on project open** — pin a directory, get the arrangement
  and the commands running, cd'd correctly.
- Apply a template **to the live window on demand** (palette / prefix binding),
  no relaunch — reusing the existing programmatic rebuild.
- A **"Save current layout as template"** action, so templates are captured
  from a working arrangement rather than hand-authored.

## Non-goals

- A named-layout catalog with list/rename/delete UI. One template per project
  plus one global default is the whole surface; grow to a catalog only if
  templates prove insufficient (per the deferred note's guidance).
- Cross-relaunch behavior changes. Auto-restore (`workspace.json`) +
  `preserve-sessions` still own "recreate my setup after restart" — templates
  are for *first* open / on-demand, not restore.
- Editing templates in a GUI beyond save/clear. The stored file is
  hand-editable JSON.

## The key finding this plan turns on

`Surface` (`Sources/ZettyCore/Model/Surface.swift:8`) **already has**
`workingDir: String` and `command: String?`, and both already round-trip
through `workspace.json` via Codable. **But `Surface.command` is dormant** —
nothing consumes it at launch. The live launch command comes only from the
session-preservation closure (`surfaceCommand`,
`SurfaceRegistry.swift:113` ← `sessionCommandProvider`,
`TerminalViewController.swift:170` ← `SessionPersistence.attachCommand`). So
the load-bearing change is: **make the launch honor `surface.command`.**

## Architecture

### 1. Honor `surface.command` at spawn (App — `SurfaceRegistry`)

`pair(for:)` (`SurfaceRegistry.swift:289`, the merge at `:300–305`) currently
sets the ghostty `command` only from the preservation closure. Extend it to
also apply `surface.command`. **The zmx wrinkle is the one real complication:**

- **preserve-sessions OFF:** the pane's ghostty `command` is free — set it to
  `surface.command` directly (runs instead of the bare shell). Simplest path.
- **preserve-sessions ON:** the ghostty `command` is *already* the zmx attach
  (`env -u ZMX_SESSION zmx attach zetty-<id>`,
  `SessionPersistence.swift:32`) — it replaces the shell, so we can't also set
  `surface.command` as the ghostty command. Instead, run the startup command
  **inside** the session after attach: once the pane's view is live, deliver
  `surface.command + "\r"` via the existing `registry.sendText` path (the same
  primitive broadcast/`zetty send` use). This also means the command re-runs
  only on first creation, not on every reattach — which is the correct
  behavior (a preserved session already has its process running; we must not
  re-launch it on relaunch).

Guard: only inject the startup command on **initial** spawn of a surface, never
on reattach of a preserved session. Track via a "launched" set keyed by
`Surface.id`, or gate on whether the zmx session already existed.

### 2. Template type + builder (`ZettyCore` — pure, tested)

A layout template is structurally just `[Tab]` (or a `Session`) reusing the
existing Codable types — `Tab` / `Layout` / `SurfaceNode` / `Surface`
(`Project.swift:3`, `Layout.swift:30`, `SurfaceNode.swift:9`,
`Surface.swift:8`). Define a thin wrapper:

```
struct LayoutTemplate: Codable {
    var schemaVersion: Int          // start at 1
    var tabs: [TemplateTab]         // title + SurfaceNode tree
}
```

where template panes store `workingDir` **relative to the project root** and an
optional `command`. New pure functions in `ZettyCore`:

- `LayoutTemplate.capture(from tabList: TabList, rootPath:) -> LayoutTemplate` —
  snapshot the live arrangement, making cwds relative to root, carrying forward
  the panes' current commands (best-effort; may be empty).
- `TabList(applying template: LayoutTemplate, rootPath:) -> TabList` (or a free
  builder) — the inverse of `freshTree(workingDir:)`
  (`TabList.swift:129`): build a `TabList`/`[PaneTree]` whose surfaces carry
  absolute `workingDir` (root + relative) and `command`. This is the piece that
  replaces "seed one default pane."

Pane-tree geometry (split direction/ratio) comes straight from the stored
`SurfaceNode` tree — no new layout math.

### 3. Template storage (`ZettyCore` — new store, mirrors `WorkspaceStore`)

The flat `key = value` config format (`AppConfig`, full-line `#` comments) can't
carry a nested tab/split tree, so templates get their own JSON store modeled on
`WorkspaceStore` (`WorkspaceStore.swift:3`):

- **Global default:** `<AppSupport>/zetty/layout-template.json`.
- **Per-project (optional):** the template lives as the `layoutTemplate` field
  of `.zetty/project.json` in the project root — lets a repo ship its own dev
  layout, and makes templates shareable via git. Per-project wins over global
  when both exist. (This repo file is defined by
  [`2026-07-04-per-project-settings-design.md`](2026-07-04-per-project-settings-design.md),
  which consolidates what was originally a standalone `.zetty-layout.json` here.)

Load in `AppDelegate` alongside `workspaceStore`/`configStore`
(`AppDelegate.swift:52,35`). No change to `workspace.json`'s schema — templates
are a separate concern from the live workspace snapshot.

### 4. Apply on open + on demand (App — `TerminalViewController`)

The programmatic rebuild is **not** relaunch-specific — `restore(workspace:)`
(`:342`) swaps the model and `rebuildSurfaceNodeView()` (`:1782`) renders
whatever the model holds, spawning panes lazily via the registry.
`selectProject` / `newTab` / `addProjectFromURL` all already
mutate-then-rebuild at runtime. So:

- **On open:** in `addProjectFromURL(_:name:)` (`:1540`) / `addProject(...)`
  (`:1089`), if a template resolves for the project, build the `TabList` from
  it (step 2) instead of seeding a single default pane, then the existing
  `rebuildSurfaceNodeView()` tail does the rest.
- **On demand:** a new `applyLayoutTemplate(_:)` entry point that installs the
  built `TabList` into the active `ProjectRuntime` and calls
  `rebuildSurfaceNodeView()` + `refreshTabBar()`/`refreshSidebar()`. Exposed via
  command palette + a `apply-layout` `BindingCommand`.
- **Save:** a `save-layout` palette/menu action → `LayoutTemplate.capture(...)`
  → write via the store.

### 5. Optional CLI (follow-up)

Today `ControlProtocol` `new-tab`/`split`/`add-project` accept **no** spawn cwd
or command (`--cwd` is only a *target selector*, not a spawn dir —
`ControlCLI.swift`). A future `zetty split --cwd X --command Y` /
`zetty layout apply` would let scripts drive templates, but the file-based
template already covers the "repeating ritual" use case, so this is deferred to
its own plan.

## Edge cases

- **Preserved-session re-launch (the big one):** never re-run a template's
  startup command on reattach — only on first creation. See §1's guard. A
  reattached pane already has its process; re-injecting the command would spawn
  a duplicate.
- **Startup command in a zmx session:** delivered via `sendText` after the view
  is live, so it needs the view to exist — same "no live view → no-op" caveat
  as broadcast. Sequence the injection off the pane-spawn callback, not
  synchronously in `pair(for:)`.
- **Relative cwd escaping the root / missing subdir:** resolve
  `root + relative`; if the directory doesn't exist, fall back to the project
  root (don't fail the whole open) and note it. Reject `..` traversal above root
  when capturing.
- **Template drift vs. live workspace:** applying a template on demand *replaces*
  the project's current tabs — confirm before discarding a non-trivial live
  arrangement (reuse the close-tab confirmation pattern).
- **Empty / malformed template file:** `decodeIfPresent` + a schema-version
  check (like `Workspace.init(from:)`); on failure, log and fall back to the
  single-default-pane behavior. A bad `.zetty-layout.json` in a repo must never
  brick project open.
- **preserve-sessions ON + template:** the template defines geometry + initial
  commands; once running, zmx keeps them alive normally. Applying a template a
  second time creates fresh sessions for the new surfaces (new UUIDs).

## Testing

`ZettyCoreTests` (pure — the bulk of the logic lives here):

- `LayoutTemplate` Codable round-trip; forward-compat via `decodeIfPresent`;
  schema-version mismatch handled.
- `capture(from:rootPath:)`: absolute cwds → relative; `..`-above-root rejected;
  commands carried; nested split tree preserved (direction/ratio).
- `TabList(applying:rootPath:)`: relative cwds → absolute; missing subdir →
  root fallback; command set on `Surface.command`; tree geometry matches the
  template; multi-tab templates produce the right `[PaneTree]`.
- Round-trip `capture` → `apply` is structure-preserving.

App layer (honoring `surface.command` at spawn, the preserved-session
inject-once guard, live apply/rebuild) is manual — GUI/PTY capture is
TCC-blocked. Manual script: author a 3-pane template with a startup command per
pane, open a fresh project, confirm the arrangement + commands with
preserve-sessions both OFF and ON, then relaunch and confirm commands do **not**
re-run.

## Rollout

1. Commit 1: `LayoutTemplate` type + `capture`/`apply` builders + template store
   + tests (all pure, no behavior change yet).
2. Commit 2: honor `surface.command` at spawn (`SurfaceRegistry.pair`) with the
   preserve-sessions inject-once path + guard.
3. Commit 3: apply-on-open in `addProjectFromURL`/`addProject`; global +
   per-project template resolution wired in `AppDelegate`.
4. Commit 4: on-demand `applyLayoutTemplate` + `save-layout`/`apply-layout`
   commands, palette + menu entries.
5. *(Optional follow-up, separate plan)* CLI spawn `--cwd`/`--command` +
   `zetty layout apply`.
