---
paths:
    - "Mods/**"
    - "Sources/ZettyCore/Agents/AgentUsage.swift"
    - "Sources/ZettyCore/Agents/ModInstall.swift"
    - "Sources/ZettyCore/StatusBar/ContextMeter.swift"
    - "App/Sources/App/AgentUsageWatcher.swift"
    - "App/Sources/App/ModInstaller.swift"
commands:
    - "claude plugin validate"
    - "claude plugin test"
triggers:
    - "changing any file of a mod under Mods/ — bump version in its plugin.json in the same change"
    - "changing Zetty's Claude Code mod or what it reports"
    - "changing the context readout, or adding chrome fed by agent usage"
    - "the context readout is missing or stale"
---

# Claude Code mod (zetty-bridge)

> Feature deep-dive, kept out of `CLAUDE.md` / `AGENTS.md`. This file is
> authoritative: edit it here, then run `hydra sync`.

Zetty ships a Claude Code **mod** — a TypeScript hooks module that runs INSIDE
the Claude Code process — at `Mods/zetty-bridge/`. It reports what the classic
hooks cannot see (context fill, cost, rate limits, why a turn ended). The
status bar's `ctx 15%` readout is its first consumer.

Pure model in `ZettyCore`: `AgentUsage` + `AgentUsageStore` (the snapshot and
its change detection), `ContextMeter` (label, level, tooltip), `ModInstall`
(when to copy, what the variable holds). App layer: `ModInstaller`,
`AgentUsageWatcher`, `StatusBarView.setContext`.

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
3. `AgentUsageWatcher` polls that directory (1s, mtime-gated) into
   `AgentUsageStore`; a visible change requests a coalesced status-bar refresh.
4. `refreshStatusBar` hands `StatusBarView` a `ContextMeter` for the focused pane.

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
  one percent and are tooltip detail, so they are excluded from the comparison
  (`AgentUsage.visible`). A cost crossing a cent boundary once woke the chrome
  mid-turn in a test; that is what the exclusion is for.
- **The readout sits LAST in the status bar's left cluster and pads its
  figure.** It changes while an agent works, and anything in `pillStack` that
  changes width on a timer slides Broadcast out from under the pointer (see
  `chrome-layout.md`). `ContextMeter.label` pads the number to three columns so
  in the mono font the label's own width holds too. It is in the `squeezable`
  list so it cannot raise the window floor, and compact hides it.
- **`setNeedsChromeRefresh(statusBar:)` exists for this.** A tab-bar refresh
  reaches the status bar too, but returns early in tile mode and re-evaluates
  every pill on the way.
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

## Verifying

```sh
claude plugin validate Mods/zetty-bridge
claude plugin test Mods/zetty-bridge
```

Loading was verified headless: with `ZETTY=1`, a `ZETTY_SURFACE` and
`CLAUDE_CODE_PLUGIN_DIRS` set, `claude -p` wrote a snapshot with no prompt.
The mod API is early access and moves between Claude Code releases; a module
that fails to load is skipped and nothing else changes, which is why no
existing hook was removed.

The wider plan — account limits, an errored dot, in-pane UI, agent tools — is
`docs/superpowers/specs/2026-10-04-claude-mod-integration-design.md`.
