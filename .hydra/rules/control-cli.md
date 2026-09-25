---
paths:
    - "Sources/ZettyCore/CLI/**"
    - "App/Sources/App/ControlSocketServer.swift"
    - "App/Sources/App/CLILink.swift"
    - "App/Sources/App/main.swift"
triggers:
    - "adding or changing a zetty CLI verb"
    - "changing the control socket or StatusSnapshot"
---

# Control CLI (zetty)

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

The app hosts a Unix control socket (`~/.zetty/zetty.sock`, 0600,
line-JSON — `ControlWire` in `ZettyCore/CLI/`) and the `zetty` CLI drives
it. **The app binary doubles as the CLI** when invoked with a recognized
command (`main.swift` branches before AppKit starts); Settings (⌘,) →
Command Line installs a symlink at `~/.local/bin/zetty`. A standalone
executable also builds via `swift build` (`.build/debug/zetty`). All CLI
logic is shared in `ControlCLI` (ZettyCore, pure Foundation).

Commands (see `zetty --help` for full grammar and agent notes):
- `status [--json]` — projects → tabs → panes: 8-hex pane ids, emitted
  titles, cwd, probed tool, agent status, focused pane.
- `send [--pane <id> | --cwd <path>] [--key <name>]… [--enter] [text…]` —
  inject text/keys into a pane's pty (tmux-style key names incl. C-a…C-z).
- `capture [--pane|--cwd] [--lines <n>]` — a pane's recent output via its
  preserved zmx session (`zmx history`).
- `view <path>[:line[:col]]` — open a file sensibly: text peeks in the read-only
  overlay at that line, anything else goes to its default app (see "Read-only
  file viewer"). No pane target (the overlay belongs to the window), and no
  preserved session needed — the agent-facing path into the viewer. Relative
  paths resolve against the CLI's own cwd (like `add-project`), so invoking it
  inside a pane resolves against that pane's directory. A fast verb: the read
  happens async after `handleOnMain` returns, so `.ok` means "accepted", not
  "rendered".
- `new-tab [--project <name>] [--focus]` / `split [--pane|--cwd]
  [--horizontal] [--focus]` / `break [--pane|--cwd] [--focus]` — create a
  tab / split a pane / break a pane into a new adjacent tab, in the
  BACKGROUND by default (active project + keyboard focus stay put, so an
  agent can reshape the workspace mid-type); `--focus` switches to the
  result. All print the new pane's bare id for command substitution.
- `add-project <path> [--name <name>]` — add a directory as a project
  (name defaults to the directory name) and make it active; the CLI
  resolves relative paths against its own cwd, and the path must be an
  existing directory not already used by a project. Prints the new
  project's first pane id.
- `remove-project <name>` — remove a project (case-insensitive), closing
  its tabs/panes and ending their zmx sessions; no confirmation dialog,
  and the last remaining project can't be removed.
- `scratch [--focus]` — open a project-less, ephemeral scratch terminal
  (rooted at home, never persisted) in the Scratch section, in
  the BACKGROUND by default; `--focus` switches to it. Prints the new pane
  id. `scratch-clear` closes and clears every scratch terminal at once.
- `tiles [--on|--off] [--profile <name>]` toggles the grid. `tiles list|open|
  new|rename|duplicate|delete` manage the saved views, and `tiles attach|
  detach|split` edit one. Those three work on the active view (or `--view
  <name>`), take 1-based `--slot` numbers, and never bring the grid up. See
  `.hydra/rules/tile-mode.md` → "Scripting the grid".
- `focus (--pane|--cwd)` · `close (--pane|--cwd) [--tab]` · `reload` ·
  `quit [--kill-sessions]` (no dialog; the flag kills every preserved
  session first — full shutdown).

Errors go to stderr with exit 0/1/2; pane targets resolve by unique id
prefix, unique cwd, or default to the focused pane. Server handlers run on
the main thread (`ControlSocketServer` → `AppDelegate.startControlSocket` →
`TerminalViewController` snapshot/send/split/close/capture).

### Dormant panes are the CLI's problem, not the caller's

A pane has no terminal behind it in two unrelated cases — its tab was never
viewed (shells spawn lazily, only for the ACTIVE tab of the ACTIVE project) or
its project is hibernated (panes deliberately freed). Both used to surface as
one message, `"has no live terminal yet — focus its tab first"`, whose advice is
actively wrong for the hibernated case: `selectProject` shows a dormant project
without waking it, so focusing changed `isActive`/`isFocused` and nothing else.
`status` exposed neither state, so a script had to guess.

Two halves fix it, both regression-tested:

- **`StatusSnapshot` reports why.** `Project.hibernated` + `Pane.live` (from
  `SurfaceRegistry.isLive`, deliberately the same `as? AppTerminalView` guard
  `sendText` uses so the flag can't disagree with whether a send lands). Both
  decode via hand-written `init(from:)` defaulting to `false`, so an older
  standalone `zetty` build doesn't throw on a newer app's payload. Plain-text
  rendering lives in the pure `ControlCLI.statusLines` (`☾ name (hibernated)`,
  `-` per dead pane) so the markers are unit-testable.
- **`ensurePaneIsLive(at:)` is the only place that knows the rule.** It wakes the
  project if needed, transiently selects that project AND the pane's tab (the tab
  half is load-bearing — waking alone leaves a background tab just as dead), then
  restores the caller's prior selection. Switching away does NOT undo the spawn:
  `allSurfaceIDs` covers every awake project, so `prune` spares the new pair.
  That's what lets a background verb return a genuinely live pane without
  stealing the view — the same select-then-restore shape `closePane` uses.

Adoption: `send` always (which also fixes ordinary never-viewed background
panes); `new-tab`/`split`/`break` when the target project is hibernated;
`focus` wakes and *stays* (switching is its purpose). `close` needs nothing — it
already worked against a dormant project. **`capture` deliberately refuses**
rather than waking: hibernating killed the zmx session it reads, so a wake would
spawn a fresh empty shell in exchange for nothing.

A freshly spawned shell can't read its pty for a moment (a new zmx session plus
the scrollback-restore wrapper can take seconds), so a `send` that had to spawn
the pane defers delivery by `spawnGracePeriod` — the same constant, now shared,
that template startup commands use. Exit 0 therefore means "delivered or
queued". The pty buffers the text, so slow shells still get it.
