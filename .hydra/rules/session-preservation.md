---
paths:
    - "Sources/ZettyCore/Session/**"
    - "Sources/ZettyCore/Recovery/**"
    - "App/Sources/App/ZmxRunner.swift"
    - "App/Sources/App/ScrollbackRestore.swift"
    - "App/Sources/App/RestartRecoveryRunner.swift"
    - "App/Sources/App/AgentSessionLookup.swift"
commands:
    - "zmx "
    - "zetty quit"
triggers:
    - "changing preserve-sessions or zmx session handling"
    - "restart recovery or resuming agents after a power-off"
    - "a preserved pane reattaches wrong, loses scrollback, or launches a plain shell"
    - "changing scratch panes or how sessions are reaped"
---

# Session preservation, restart recovery and reattach

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

- **`preserve-sessions = true|false`** (default false) — panes run inside
  [zmx](https://zmx.sh) sessions (`zmx attach zetty-<uuid8>`, one per pane) so
  they survive app quit/relaunch; reattach replays terminal state. Quit
  survives, explicit close kills (via `registry.prune` → `zmx kill`); a
  one-shot startup reap kills `zetty-*` sessions no restored surface owns
  (crash leftovers), and Settings offers a manual kill too. The ORPHAN diff
  uses `WorkspaceModel.sessionOwnerSurfaceIDs` (ALL projects, hibernated
  included), because the same pass sweeps `<uuid>.cwd` files and a dormant
  pane needs its cwd to wake at. **A hibernated project owns no SESSIONS,
  though**: hibernation's kill is best-effort (zmx missing, a crash, or a tile
  respawning a pane), and `reconcileSessions` ends any survivor through the
  hibernation teardown (`endLeftoverSessionsOfHibernatedProjects`, see
  `surfaces-and-memory.md`). This reverses the earlier rule that spared them —
  the user's ruling: a hibernated project must have no session at all. The
  Settings (⌘,) toggle offers to download the zmx release binary from zmx.sh
  into `~/.zetty/bin` when missing (Homebrew/manual installs are detected
  too); config-only enablement without zmx falls back to plain shells with a
  one-time alert. Pure logic in
  `ZettyCore` (`SessionPersistence`); process IO in `ZmxRunner`.
  Reattach gotchas handled in the app layer:
  - **`ZMX_SESSION` is stripped** from the attach command (`env -u`) and from
    every zmx subprocess: inherited from a zmx-backed terminal (Supacode, or
    Zetty itself), `zmx attach` would *kill* that session instead of
    attaching the target.
  - **Repaint nudge** — zmx replays screen contents but a running TUI paints
    only deltas, so a reattached pane stays half-drawn; ~1s after a pane's
    surface appears it is shrunk ~20pt and restored (SIGWINCH → full repaint).
  - **Scrollback restore** — `restore-scrollback` (default true): panes launch
    through a generated wrapper (`~/.zetty/scrollback-restore.sh`, contents in
    `SessionPersistence.restoreScriptContents`, written idempotently by
    `ScrollbackRestore.ensureScript()`) that replays `zmx history <session>
    --vt` into the surface before exec'ing the attach — full scrollback with
    attributes survives quit/relaunch. Plain-token invocation (`/bin/sh
    <script> <zmx> <session>`) because ghostty's `command` parser can't be
    relied on for quote grouping; the script's `unset ZMX_SESSION` covers the
    strip for both zmx calls. Script write failure falls back to the bare
    attach (session preserved, replay lost).
  - **Scratch panes ARE preserved, and that is a deadlock fix, not a feature.**
    Without a session a scratch pane's pty child is the shell with its agent
    under it; closing such a pane while that agent is still writing wedges the
    main thread FOREVER — `Subprocess.stop` stops draining the pty while waiting
    for a child that is blocked writing to it, and `Surface.deinit` joins that
    thread from main. `SIGKILL` cannot clear it (the child is unreapable until
    the pty dies) and recovery is `kill -9` on Zetty. It fired on consecutive
    mornings from a scratch pane running Claude. With a session the pty child is
    a `zmx attach` LEAF, which dies cleanly — UNLESS it is mid-write when the
    surface stops draining: that froze the app 2026-10-06 on a preserved
    pane. Closing now ends the session before freeing; see
    `surfaces-and-memory.md` → "Closing a pane". Scratch follows the GLOBAL
    `preserve-sessions` only — it is rooted at home and would otherwise adopt
    the settings of whatever project shares that path — and
    `AppDelegate.killScratchSessions()` ends those sessions in
    `applicationWillTerminate` (the one choke point every quit path reaches), so
    none outlives its pane. That last part is load-bearing: scratch hosts
    account sign-ins, and a surviving session would carry that account's
    environment. Spec: `docs/superpowers/specs/2026-09-18-scratch-pane-deadlock-design.md`.
  - **Title persistence** — zmx never replays the title escape sequence, so
    each surface's last emitted title persists as `Surface.lastTitle` in
    `workspace.json` and seeds the tab name until the program emits a fresh
    one (`SurfaceRegistry.title` returns nil for the empty initial title so
    the fallback engages).

  - **Restart recovery** (`zetty-restart-recovery`, default true; spec
    `docs/superpowers/specs/2026-09-04-restart-recovery-design.md`). A
    restart/shutdown/logout kills zmx too, so `applicationShouldTerminate`
    classifies the quit from the Apple Event's `kAEQuitReason` (pure
    `QuitReason`; ⌘Q/`zetty quit`/`NSApp.terminate` carry no reason → ordinary),
    returns `.terminateLater`, captures `zmx history --vt` per preserved pane
    within `RestartRecovery.shutdownBudget` (5s, atomic per-file writes — a late
    finisher leaves a whole unreferenced file the next launch sweeps, never a
    partial one), writes `~/.zetty/restart-recovery.json`, and ALWAYS replies
    true — never cancel a shutdown. **The manifest is the only signal that
    sessions died from a power-off**; the next launch deletes it the moment it
    reads it, so a crash mid-recovery can't loop, and its absence (crash, panic,
    plain quit) is the ordinary path. Snapshots replay through the wrapper
    script's third argument (`attachCommand(…, snapshotPath:)` — passed only for
    manifest surfaces, so an ordinary launch renders byte-identical commands);
    resumes (`RestartRecovery.resumeCommand`:
    `cd '<agent cwd>' && claude --resume '<id>'` / `codex resume '<id>'`, ids
    validated `[A-Za-z0-9._-]{1,128}` at hook-parse time, cwd single-quoted via
    `ShellQuote`) go through `pendingStartupCommands` — the
    never-re-run-into-preserved-sessions rule holds because the manifest exists
    only when those sessions are dead. The session id comes from hook payloads
    (Claude `session_id`, Codex `thread-id`) into `AgentState.session`; Claude
    also gets a `SessionStart → idle` hook so `/clear` and `--resume` refresh
    the id (`idle`, never `running` — a just-started agent is waiting). Launch
    at login is `SMAppService.mainApp` with NO config key (system-owned state,
    same reasoning as `zetty-home-path` being a single source) — and it
    registers whichever bundle called it, so toggle from `/Applications`.
    `zetty quit --simulate-restart` is the test path, reusing
    `performPowerOffRecovery(killingSessions: true)`. To exercise the REAL path
    without losing sessions, send the app the same Apple Event macOS sends
    (`kAEQuitApplication` + `kAEQuitReason` = `kAERestart`): it runs
    classification, snapshot and manifest with `killingSessions: false`, so a
    session hosting the tester survives.
  - **Session ids come from TWO sources, and the probe outranks the detector.**
    Hooks name the pane exactly but only fire when the agent acts, so a
    long-running Claude or a Codex pane that never finished a turn would resume
    nothing — on the reference workspace hooks alone covered 2 of 11 panes.
    `AgentSessionLookup` (App) therefore reads each harness's OWN store for any
    agent pane the probe sees without a session: Claude's
    `~/.claude/projects/<slug>/<id>.jsonl` (file name IS the id; slug = every
    non-alphanumeric character → `-`, undocumented so a candidate is CONFIRMED
    against the `cwd` recorded inside before use) and Codex's
    `~/.codex/sessions/<date>/rollout-*.jsonl` (first line carries `id` + `cwd`;
    `codex resume --last` is NOT used — it is global, not per-directory, so it
    would resume one pane's conversation into another). Policy is pure in
    `AgentSessionStore`: newest-first, one per pane, never a duplicate, never an
    id a hook already claimed. **The agent KIND for a looked-up session must
    come from the probe, not `AgentState.kind`** — a pane can carry a stale kind
    from the era when hook events matched by directory, which produced
    `codex resume <claude id>` for two panes; the `resume tally` log line records
    probe/detector/chosen so it can't regress unseen.
  - **A captured snapshot must be SANITIZED before it is replayed**
    (`SnapshotSanitizer`, pure + tested). `zmx history --vt` reproduces what the
    pane emitted, and an agent killed by the power-off never undid its terminal
    modes — every real snapshot carried `?1049h` (alt screen) plus
    `?1000h`/`?1002h`/`?1003h`/`?1006h` (mouse) and `?2004h`, with no resets.
    Replayed verbatim into a fresh shell that leaves the pane hostile: the shell
    runs inside the alternate screen (so the replay is invisible in scrollback
    AND no divider appears) and mouse reporting stays on with no TUI to consume
    it, so every pointer movement types an escape at the prompt — observed as a
    pane full of `zsh: command not found: 39`, whose interleaved bytes also
    mangled the resume being typed into it, so that pane's agent never came
    back. The sanitizer strips every DEC private mode set/reset and any scroll
    region, keeps text/SGR/cursor motion, and appends a reset trailer
    (margins, attributes, cursor, mouse off).
  - **Recovery panes are spawned eagerly but STAGGERED**
    (`spawnPanesAwaitingResume`, `resumeSpawnInterval` 2s). A pane has no pty
    until its tab is shown and the resume rides on that spawn, so a project's
    non-active tabs would wait for a click; the fix reuses the CLI's transient
    `ensurePaneIsLive` select-spawn-restore so the view never moves. Spacing is
    load-bearing, not politeness: each pane costs a GPU surface and starts an
    agent process, and 11 agents launching together took the reference machine
    past load 35. Hibernated projects are skipped — they were dormant before
    the power-off and waking them would spawn work the user put away.
  - **A resume comes back under the login its agent was RUNNING as.** A
    recovered pane respawns a shell carrying the account it was SPAWNED with,
    so an agent started by `zetty run <account>` would otherwise resume under
    the wrong login, and the session lookup would scan the wrong config dir.
    The tally records `Entry.agentAccount` (the harness's account, read on main
    via `harnessAccount` before the off-main tally; the lookup gets
    `Target.configDirectory`). At relaunch `RestartRecovery.pinnedLogin`
    prefixes that login's `CLAUDE_CONFIG_DIR` / `CODEX_HOME` onto the resume
    when it differs from the spawn account — or, for the DEFAULT login in a
    pane spawned on an account, removes it with `env -u` (the tally records
    `@default` too, for exactly this) — which is why `agentAccounts` loads
    BEFORE the manifest is applied. `holdRunningAccountForResume` re-sets
    `runningAccountID` and HOLDS it: the resume waits `resumeGracePeriod` in a
    bare shell, and the foreground probe would otherwise read that shell as
    the `zetty run` having ended and clear the override the resume is about to
    bring back. The hold lasts until the probe sees the agent, or 30s past
    delivery.
  - **A resume is never typed into a pane whose agent is still running.** The
    manifest assumes the power-off killed everything, and a restart CANCELLED
    after Zetty quit breaks that: the app relaunches, sessions are alive, and
    the resume lands in a live agent's prompt (observed for real). Resumes are
    queued guarded (`queueStartupCommands(_:asAgentResume:)`), wait
    `resumeGracePeriod` (4s, past the foreground probe's first poll), and are
    dropped when the probe reports an agent in that pane. Template and clone
    startup commands stay unguarded — they only ever target new panes.
