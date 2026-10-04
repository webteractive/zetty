---
paths:
    - "Mods/**"
    - "Sources/ZettyCore/Agents/AgentUsage.swift"
    - "Sources/ZettyCore/Agents/ModInstall.swift"
    - "App/Sources/App/AgentUsageWatcher.swift"
    - "App/Sources/App/ModInstaller.swift"
    - "Sources/ZettyCore/Accounts/AccountLimits.swift"
commands:
    - "claude plugin validate"
    - "claude plugin test"
triggers:
    - "changing any file of a mod under Mods/ — bump version in its plugin.json in the same change"
    - "changing Zetty's Claude Code mod or what it reports"
    - "adding chrome fed by agent usage (rate limits, cost, context, turn outcome)"
---

# Claude Code mod (zetty-bridge)

> Feature deep-dive, kept out of `CLAUDE.md` / `AGENTS.md`. This file is
> authoritative: edit it here, then run `hydra sync`.

Zetty ships a Claude Code **mod** — a TypeScript hooks module that runs INSIDE
the Claude Code process — at `Mods/zetty-bridge/`. It reports what the classic
hooks cannot see (context fill, cost, rate limits, why a turn ended).

What reads it: the account chip and pickers (rate limits), every status dot
(a failed turn), the needs-attention notification (its message), the Sessions
view (cost), and the agent resume line (session id).

Pure model in `ZettyCore`: `AgentUsage` + `AgentUsageStore` (the snapshot and
its change detection), `AccountLimits` + `AccountLimitLabel` (limits per
account, and how they read), `AgentStatus.displayed` (the errored overlay),
`ModInstall` (when to copy, what the variable holds). App layer:
`ModInstaller`, `AgentUsageWatcher`, `TerminalViewController.applyAgentUsage`.

## Do not show the context window in Zetty's chrome

A status-bar readout (`ctx 15%`) shipped in v0.1.49 and was removed the same
day. **Claude Code's own status line already shows context fill, inside the
pane it describes**, so a second copy in Zetty's bar was a duplicate one line
away, and it only ever described the focused pane. The same reasoning covers a
context figure in a tile's status line or the Sessions view: the tile already
contains the pane that shows it.

What Zetty's chrome is for is what Claude Code CANNOT show: state across
panes and across accounts. Rate limits belong to an account rather than a
pane, and an errored turn matters in a pane you are not looking at. Before
adding chrome fed by the snapshot, check whether the harness's own status line
already carries it for the pane in view.

## Any change to a mod bumps its version  ← not optional

**If any file under `Mods/<name>/` changes, bump `version` in
`Mods/<name>/.claude-plugin/plugin.json` in the same change.** Hooks, the
manifest, `hooks.json`, a contract under `types/` — all of it. Only `tests/`
is exempt, because tests are never copied out.

`ModInstall.needsInstall` compares the bundled version with the installed one
and nothing else. A mod edited under an unchanged version is therefore never
copied to `~/.zetty/mods`: the app builds, installs and restarts cleanly, and
every Claude pane goes on running the OLD mod. Nothing fails and nothing logs,
so it reads as "my change did nothing".

- Patch for a fix, minor for a new field or hook. A change to the snapshot
  that an older reader cannot parse also bumps `v` in the snapshot and
  `AgentUsage.supportedVersion` — that is a different number with a different
  job.
- Check before committing: `git diff --stat HEAD -- Mods/` lists a mod file
  other than a test, so `git diff HEAD -- 'Mods/*/.claude-plugin/plugin.json'`
  must show the `version` line changed.
- After installing, confirm the copy took:
  `grep version ~/.zetty/mods/zetty-bridge/.claude-plugin/plugin.json`.

## The path, end to end

1. `ModInstaller` copies the bundled mod to `~/.zetty/mods/zetty-bridge` and
   sets `CLAUDE_CODE_PLUGIN_DIRS` process-wide, so every pane inherits it.
2. Claude Code loads the mod. On session start, turn start/end and every
   `session.measure` it rewrites `~/.zetty/agent-usage/<SURFACE-UUID>.json`.
3. `AgentUsageWatcher` polls that directory (1s, mtime-gated) and hands each
   batch to `applyAgentUsage`, which stores it and requests a coalesced
   refresh ONLY for what moved: dots when a turn's failed state flipped, the
   status bar (tile footers in tile mode) when an account's limits moved a
   whole point.

## Rules

- **The classic hooks stay the only source of running / idle /
  needs-attention.** The mod ADDS to them. Two writers for one dot is how a dot
  ends up wrong, and Codex and Hermes have no mod at all.
- **The mod is loaded from the COPY, never from inside `zetty.app`.** Claude
  Code writes `.claude-plugin/types/` and a `tsconfig.json` beside any mod it
  loads from disk; inside the bundle that breaks the signature. Both are
  gitignored under `Mods/` for the same reason — loading the repo copy with
  `--plugin-dir` lays them there.
- **The copy overwrites file by file, manifest LAST.** A running Claude watches
  the folder and hot-reloads when it settles; deleting the folder first hands
  it a missing module, and writing the manifest first would make a copy that
  was cut short pass as current.
- **The mod cannot append.** `$.fs.write` replaces a whole file, which is why
  there is one snapshot file per pane rather than lines in
  `agent-events.jsonl`. The write is not atomic either: `AgentUsage.parse`
  returns nil for a file caught mid-write and the watcher does not record its
  date, so the next tick reads it again.
- **A snapshot file alone is never trusted.** It outlives a Claude killed
  without `session.end`. `AgentUsage.isShown(foreground:)` requires the
  foreground probe to still see `claude`; with no probe (`preserve-sessions`
  off) the snapshot's own `ended` state is all there is. The watcher deletes
  files for surfaces Zetty no longer has — but not while the surface set is
  EMPTY, which means "not restored yet", not "every pane closed".
- **`session.measure` is a machine-driven event source** and falls under the
  Chrome refresh rules. `AgentUsageStore.apply` reports a change only when
  something a view SHOWS moved: token counts and cost tick many times inside
  one percent and are excluded from the comparison (`AgentUsage.visible`). A
  cost crossing a cent boundary once woke the chrome mid-turn in a test; that
  is what the exclusion is for. The first view to read the store must refresh
  only on a `true` from `apply`, through `setNeedsChromeRefresh`, and anything
  it puts in the status bar must hold its width (see `chrome-layout.md`:
  nothing in `pillStack` may change width on a timer).
- **A pane's environment is captured once.** `zetty-claude-mod` and the
  variable apply to panes spawned afterwards; an agent already running, or any
  agent in a preserved session created earlier, keeps what it started with.
  `zetty run` inherits the pane's environment, so account launches carry the
  variable without help. A project that sets `CLAUDE_CODE_PLUGIN_DIRS` itself
  replaces the process-wide value in its panes, so `surfaceEnvironmentProvider`
  puts Zetty's path back beside it.
- **The mod reads only variables spelled as string literals** (`ZETTY`,
  `HOME`, `ZETTY_SURFACE`, `ZETTY_CWD_FILE`, `CLAUDE_CONFIG_DIR`) — the engine
  refuses a computed name. The surface is validated as a UUID before it becomes
  a path, in the mod and again in `AgentUsage.parse`.

## What the chrome shows, and the rules behind each

- **Limits belong to an ACCOUNT, not a pane.** Every Claude pane on a login
  reports the same windows, so `AccountLimits` keeps the newest report per
  account id (`@default` for the default login) and persists it
  (`account-limits.json`, beside the accounts file) — the moment of choosing
  an account for a new pane is exactly when none may be running on it. A
  report with NO windows is ignored, never stored: the harness reports none
  before its first response, and that must not wipe what another pane said. A
  window whose `resetsAt` has passed is dropped on read.
- **The account is resolved from the snapshot's `config`**, through the same
  `AgentAccountResolver.accountID(forReportedConfigDirectory:)` the hook's
  report uses. A missing `config` names nothing and records nothing.
- **The chip is quiet below 70%.** `AccountLimitLabel.chip` is nil until the
  highest window is worth a glance; the name keeps the account's own hue and
  only the appended window takes the attention / error token, so identity
  never changes colour with usage. `StatusBarView.accountTitle` is shared by
  the status bar and `TileStatusLineView`.
- **Errored is an overlay on idle, never a hook state.** `AgentStateMachine`
  and the hooks are untouched; `AgentStatus.displayed` returns `.errored` only
  for an idle (or stateless) pane whose snapshot says the last turn ended in
  `error` or `refusal`. Running and needs-attention always win, and `aborted`
  is the user's own interrupt. Roll-up order: needs-attention, errored,
  running, idle.
- **A failed turn notifies, but does not badge.** The Dock badge counts panes
  waiting on you and clears when one is visited; an error does neither.
- **The first batch never notifies.** `AgentUsageWatcher` flags the read made
  at `start()`: those snapshots describe turns that ended before this launch,
  the same reason the hook replay stays silent.
- **The attention message is read from the FILE at notification time**
  (`attentionMessage(for:)`), not from the store. The mod's
  `classic.Notification` hook writes the snapshot BEFORE calling `next`, and
  the settings hook beneath it is what raises needs-attention — so the file is
  already there, while the watcher's 1s poll may not have come round. The
  message is flattened to one line and capped at 200 characters in
  `AgentUsage.parse`, because it lands in a notification.
- **Tile dots are retuned in place** (`TileGridView.updateStatuses`, on the
  coalesced refresh). Before this they only moved when the grid was rebuilt.

## Writing the mod: what the engine refuses

Each of these failed validation or a load before it was learned; none is
obvious from the API's types.

- **Everything that touches `$` or `on` lives in ONE file,
  `hooks/register.tsx`.** The engine follows `$` only into functions declared
  in the same file, never across an import — a helper in another module that
  takes `$` makes the whole mod fail to load. `hooks/panes.ts` is therefore
  PURE (parsing, labels, the limit rule) and is the only other module.
- **One unmatched hook per event.** A second `on("session.start", …)` without
  a matcher is refused, so the pieces expose `startCommands` / `startTools` /
  `startBand` and the single `session.start` hook calls each, with its own
  `.catch`, so one failing to start costs neither the others nor the session.
- **Matchers are literals.** `{ tool: name("show_file") }` validates as
  `tool=?` and matches nothing the engine can name; each tool's full name
  (`mcp__zetty-bridge__show_file`) is spelled out.
- **`$.env.get` takes a string literal.** The variables are `ZETTY`, `HOME`,
  `ZETTY_SURFACE`, `ZETTY_CWD_FILE`, `CLAUDE_CONFIG_DIR`, `ZETTY_BIN`,
  `ZETTY_CLAUDE_TOOLS`. `ModInstaller.applyEnvironment` sets the last two
  process-wide.
- **State a drawing reads is in `$.state`**, declared in `types/index.d.ts`
  (named by `plugin.json`'s `types`), never a module variable: a hot reload
  keeps the former and restarts the latter. A render hook only reads; writes
  come from handlers and other events through `update`.
- **A file with JSX is `.tsx`**, and `hooks.json` names it. When a module is
  renamed, `ModInstaller.copyTree` sweeps what the bundle no longer ships out
  of `hooks/` and `types/` — after the new files, before the manifest.

**In-pane UI is Claude Code's surface, not Zetty's**: it uses the surface's own
elements (`$.ui.resolve(e)`), not `ZTheme`. Every render hook returns
`next(e)` when it has nothing to show. Tests mount each drawing on both
`terminal` and `desktop`, which validates the tree against each surface's
rules — it does not show what it looks like, and nothing here has been looked
at in a real pane yet.

**The mod reaches Zetty only through the control CLI** (`zetty(...)` runs
`ZETTY_BIN`): no new IPC. `list_panes` and the fleet sidebar filter
`zetty status --json` to the project containing this pane, so the rest of the
workspace is never handed to the model. `read_pane` answers only for panes
`open_pane` returned in this load of the mod.

**The clone band asks twice.** `Merge into source` changes the source repo
and `Push branch` pushes to origin; the CLI verbs behind them ask nothing, so
the band holds a `cloneStep` (`idle` → `merge`/`push` → run) and only the
second press runs `zetty merge-clone` / `push-clone`. Zetty already shows a
`CloneWarningBanner` outside tile mode; the band is what a TILE has, and
`Hide` drops it for the session. It reads `cloneOf` from `zetty status --json`
once, at `session.start`. Those two verbs get a 120 s timeout rather than the
10 s every other call has — they run git over a whole repository.

**`ZETTY_BIN` falls back to `zetty` on `PATH`.** A pane opened before Zetty
injected the variable has only that, and every preserved session predates it.

## Verifying

```sh
claude plugin validate Mods/zetty-bridge
claude plugin test Mods/zetty-bridge
```

Loading was verified headless: with `ZETTY=1`, a `ZETTY_SURFACE` and
`CLAUDE_CODE_PLUGIN_DIRS` set, `claude -p` wrote a snapshot with no prompt,
`claude -p "/zetty panes"` listed the real project's panes through the
installed app, and the model named all four tools when asked.
The mod API is early access and moves between Claude Code releases; a module
that fails to load is skipped and nothing else changes, which is why no
existing hook was removed.

The wider plan — account limits, an errored dot, in-pane UI, agent tools — is
`docs/superpowers/specs/2026-10-04-claude-mod-integration-design.md`.
