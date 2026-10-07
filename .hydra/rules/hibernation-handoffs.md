---
paths:
    - "Sources/ZettyCore/Hibernation/**"
    - "App/Sources/App/Handoff*.swift"
    - "App/Sources/App/AgentTranscript.swift"
    - "App/Sources/App/TerminalViewController+Handoffs.swift"
commands:
    - "zetty hibernate"
    - "zetty wake"
triggers:
    - "changing hibernation handoffs or hibernate-after eligibility"
    - "a hibernated pane wakes without its handoff, or into the wrong conversation"
    - "a project with an idle agent is not auto-hibernated, or a busy one is"
---

# Hibernation handoffs and hibernate-after

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

Hibernating a project has each Claude or Codex pane leave a short handoff, and
waking starts a fresh agent from it. `hibernate-after` reaches projects whose
agents are idle. Spec: `docs/superpowers/specs/2026-10-07-hibernation-handoffs-design.md`.
Pure logic is in `ZettyCore/Hibernation/`; the app layer is `HandoffStore`,
`HandoffRunner`, `AgentTranscript` and `TerminalViewController+Handoffs.swift`.
Needs `preserve-sessions` (`handoffsEnabled`); without zmx both hibernation and
`hibernate-after` behave as they did before.

## The handoff is written by a FORK, never the live pane

- **`claude -p --resume <id> --fork-session --no-session-persistence --tools ""
  --permission-prompts none "<request>"`** and **`codex exec fork <id>
  --ephemeral --skip-git-repo-check "<request>"`**, verified against claude
  2.1.292 and codex 0.160.1. The reply comes back on stdout; the agent writes no
  file. That removes a Write permission prompt, a file in the user's repo, and
  any race with the live session: a fork never appends to the original
  transcript and works while the pane's agent is alive or after it is gone.
- **That is what lets hibernation stay instant.** `hibernateProject` captures
  the records BEFORE the teardown (the probe, the hook state and the running
  login are gone after it) and queues the forks AFTER it. Do not move the
  capture, and do not make the teardown wait for a fork.
- **`--tools ""` is the safety, not the permission mode.** The user's own allow
  rules could let a tool run for real. `--permission-prompts none` sits between
  it and the request because `--tools` is variadic and would swallow the
  request as a tool name; `HandoffForkTests` pins the order.
- **No `--model`.** A long session may not fit a smaller model's context.
- **stdin is `/dev/null`.** `claude -p` otherwise waits 3 seconds for piped
  input.
- **The fork's environment carries no pane identity, no agent session and no
  stale login** (`HandoffFork.environment`). `ZETTY` goes because `AppDelegate`
  sets it on the app itself and the hook helper reports whenever it is set,
  falling back to matching panes by DIRECTORY when it has no surface: a fork
  carrying it would flip other panes' dots and consume the wrong handoff.
  `USER` must survive: without it Claude cannot read an account's Keychain
  login and answers "Not logged in".
- **A handoff never blocks anything.** No binary, a failed resume, a timeout
  (5 minutes), an empty reply or one over 200 000 bytes all end the same way:
  the record is removed and the pane wakes as a plain shell. A fork under the
  wrong account fails in about 2 seconds ("No conversation found").
- **At most two forks run at once** (`HandoffQueue.maxRunning`). Each is a cold
  read of a whole transcript on one account's rate limit.
- **Quitting SIGKILLs running forks.** A fork is the app's child and would
  outlive it; SIGTERM followed by a delayed SIGKILL loses the second half to
  the quit. Their records stay, and the next launch queues them again.
- **A model can decline.** One Haiku fork answered a test question with a
  refusal and exit 0, which would have been stored as a handoff. Not guarded.

## Files

- `~/.zetty/handoffs/<SURFACE-UUID>.json` is the record (harness, session id,
  directory, account); `.md` beside it is the wake file. Directory `0700`,
  files `0600`, written to a temporary name and renamed.
- **A record with no `.md` is a handoff still owed; with one it is ready.**
  `HandoffStore.begin` clears a stale `.md` first, so a fork that fails this
  time cannot wake the pane from last time's text.
- **The record exists because the wake needs it after a relaunch.** The file
  name carries no harness, session or login.
- **The wake file holds the wake line AND the handoff.** A mention inside a
  mentioned file is not expanded (Tinker learned this).
- **A hibernated pane has no surface to prune**, so closing it or removing its
  project reaches no close hook. Its files are swept in `reconcileSessions` by
  the ownership question the `<uuid>.cwd` files use, and a fork still owed for a
  pane that is gone is cancelled there.

## Waking

- **`HandoffWake.plan` decides per pane:** a ready handoff starts a fresh
  agent; a fork still queued or running is CANCELLED and the pane resumes its
  old conversation (a wake within moments is a change of mind, and the one
  exception to waking fresh); anything else is a plain shell.
- **Claude mentions the file** (`claude '@/abs/path'`, absolute, never `~`);
  **Codex gets its text** (`codex "$(cat '/abs/path')"`), which Claude also
  gets when the path holds whitespace a mention cannot carry.
- **Every wake line goes through the guarded startup path**
  (`queueStartupCommands(_:asAgentResume: true)`): it waits `resumeGracePeriod`
  and is dropped when the probe shows an agent in the pane. That guard reads
  `foregroundBySurface`, so hibernating clears the dead panes' entries itself;
  left stale, a scripted hibernate and wake had every line skipped.
- **The handoff is consumed only once the agent has provably read it**
  (`HandoffWake.provesHandoffRead`). Claude reports `SessionStart` as it
  launches, BEFORE it expands the mention in its first message; deleting the
  file on that event left the fresh agent holding a path to nothing, on the
  first real wake. It is consumed on the event AFTER the one that reports the
  agent running, counted since the wake and never read off the pane's status
  (which can still say `running` from an agent hibernated mid-turn). Codex is
  exempt: its shell read the file before Codex started.
- **Hooks are optional, so there is a second route:** a minute after the line
  is typed, a fresh probe reading that still shows the harness consumes it.
- **Until consumed, the file is the only record that a wake is owed.** At
  launch `restoreHandoffState` queues owed forks again and re-queues a wake
  line lost with the quit, unless restart recovery already queued a resume for
  that pane, which describes something later and wins.
- **Hibernating forgets a pane's remembered session**
  (`lookedUpResumeSessions`). The agent that comes back is a new conversation;
  kept, the next hibernation would fork the old one.

## hibernate-after

- **`HibernationEligibility.keepsAwake` replaced "any foreground process is
  busy"**, which exempted every project with an agent open. A working agent,
  one waiting on the person, a draft in the prompt box and a non-agent command
  still keep a project awake. An agent PROVEN to be at rest, at an empty
  prompt box, does not. Unknown status keeps it awake.
- **`needsAttention` is at rest too, and the screen then decides.** Claude
  fires its notification hook after a minute of sitting at its prompt, which
  arrives as the same status a permission prompt does. Read as "waiting on the
  person" it kept every idle Claude's project awake for good: the first real
  run put the idle shell away and left the idle agent. A real question
  replaces the prompt box with a menu, so an empty box under that status is an
  agent with nothing to ask.
- **An agent's own background work keeps its project awake** (Glen,
  2026-10-08). When a turn ends Claude reports `idle` and shows an empty box
  while a dev server it started keeps running, and before handoffs any
  foreground process protected that server from the timer.
  `ForegroundProcess.hasDetachedWork` finds it for Claude: it runs each
  command it starts as a session of its own with NO terminal (`??` in `ps`),
  directly beneath it, while its helpers, MCP servers and a language server,
  stay on the pane's. A different process GROUP alone is not the sign: Codex
  keeps its helpers in groups of their own, on the terminal. A detached
  process further DOWN is not either: a browser an MCP server launched hangs
  off that helper and is not work. Subagents run inside Claude's process, so
  they are caught by the clock instead: `AgentTranscript` takes the newest of
  the session's transcript and `<session>/subagents/*`.
- **Codex runs its commands under a shared daemon, not under the pane**
  (`codex` → a `codex` daemon with ppid 1 → the command). The process table
  shows nothing beneath the pane, so its screen is read instead: while a
  command runs the working line carries `1 background terminal running`, and
  at rest the line above the composer reads `1 background terminal running ·
  /ps to view · /stop to close`. `PromptBox` refuses either as empty, which is
  what keeps such a project awake.
- **The busy rule for a hibernate somebody asks for is unchanged on purpose**
  (`confirmClosingBusyPanes`, `BusyPaneGate`, `--force`).
- **Codex's hook cannot tell working from idle** (its one hook is turn ended),
  so `PromptBox.isCodexComposerEmpty` is what keeps a working Codex awake: it
  refuses any screen with an `esc to interrupt` line. That line is drawn FAINT,
  so it is searched for with faint text kept. Claude's box, by contrast, is the
  same empty `❯` while Claude works; there the hook status is the guard, and the
  fixture test asserts the box reads empty on purpose.
- **The fixtures are real screens** (`Tests/ZettyCoreTests/Fixtures/promptbox`,
  `zmx history --vt`, about one screen each because both harnesses draw on the
  alternate screen). Re-capture them when a harness changes its prompt.
- **The pass never trusts `foregroundBySurface`.** `pollForegroundAgents`
  returns early unless `NSApp.isActive`, so the map is frozen while Zetty is in
  the background, which is when projects go idle: a pane was still reported as
  running Codex long after Codex quit. `evaluateAutoHibernation` takes its own
  reading off-main, and a failed reading is unknown, never idle.
- **A harness's session store is never searched on the main thread from the
  timer.** `knownResumableSession` is what hooks, the mod and the cache say;
  `resumeLookupTarget` is searched in the pass's off-main hop.
- **Idle runs from the latest of** `ProjectRuntime.lastUsedAt` (persisted;
  stamped while on screen and on every key that reaches a pane) **and each
  agent's transcript date.** A relaunch no longer resets the clock.
- **`keptAwake`** is set by a wake somebody asked for and cleared only by a key
  reaching one of the project's panes. A background CLI verb waking a project
  (`ensurePaneIsLive`) does not set it: nobody would ever type there to clear it.
- **An agent quiet for over a week gets no handoff on an AUTOMATIC hibernate**
  (`HandoffPolicy.handoffWithin`), or the first pass after an update would
  cold-read every stale transcript in turn. By hand always writes one.

## What hibernating closes

- **Claude closes everything beneath it when its session is ended**, so
  nothing is added for it. Checked on a real hibernate three ways: a
  background command, a child in a session of its own, and one in a session
  of its own that ignored TERM and HUP. All were gone afterwards, along with
  the MCP helpers. A cleanup pass that signalled survivors was written and
  then removed: it had nothing to do, and it put an unbounded `ps` in the
  teardown.
- **Codex's commands outlive its pane**, being the daemon's: a `sleep` Codex
  had started was still running after its project was hibernated. So a Codex
  pane is told to stop first (`HibernationTeardown.Plan.stopFirst`,
  `ZmxRunner.stopCodexTerminals`): the screen is read and only what it calls
  for is typed (`PromptBox.codexStopStep`), Escape if a turn is running, then
  `/stop` ("Stopping all background terminals") if a terminal is.
- **Escape interrupts the turn, not the command.** After it the command was
  still running and the screen showed the `/stop` hint; that is why there are
  two steps.
- **`/stop` is never typed onto a draft.** It would be submitted with the
  draft as a prompt, and the daemon would carry on with that turn after the
  pane was gone. With a draft in the composer the terminal is left running.
- **The Enter goes in a write of its own.** Codex reads text and Enter
  arriving together as a paste and keeps the Enter as a newline.
- **Escape is `CSI 27 u`, not a bare ESC byte.** Codex turns on the kitty
  keyboard protocol, and a bare `0x1B` written to its session did nothing: the
  first version sent that, and a working Codex's command outlived the
  hibernate. `zetty send --key Escape` had worked in the test that preceded
  it only because Ghostty encodes the key for the protocol; `zmx send` writes
  raw bytes. The bare byte is kept as a second try.
- **A Codex started within about three seconds of the hibernate is missed.**
  The plan reads the probe's map when Zetty is in front, and the probe polls
  every three seconds: a scripted test that hibernated the instant Codex's
  command appeared found the pane still listed as a shell. Seconds later the
  same sequence worked.
- **Only a hibernate does this.** A closed pane's plan carries no probe
  reading, so a Codex pane that is closed leaves its commands running, as
  before.

## Known limits

- **A pane's session comes from a hook, the mod, or a search of the harness's
  store by directory.** The search falls back to the directory the pane was
  created in and uses physical paths (`/tmp` reports as `/tmp/…`, a rollout
  records `/private/tmp/…`). An agent started after a `cd` elsewhere, with no
  hook, gets no handoff.
- **Background work is read three ways, each for one case.** Claude's
  commands from the process table, its subagents from their transcripts,
  Codex's from its screen. A harness that changes how it runs commands, or
  rewords its hint, silently stops being seen.
- **Claude shows its spinner before it has submitted a prompt given on the
  command line.** For most of a minute at startup (three launched together)
  the status was `idle`, the box empty and the spinner turning; `running` only
  arrived with `UserPromptSubmit`. Harmless to `hibernate-after`, which needs
  minutes of idleness since the command was typed, but it is one more reason
  the box alone proves nothing for Claude.
- **The interactive mention was only seen in bypass-permissions mode.** It is
  not a tool call (it expands with `--tools ""`), but a default-mode pane has
  not been watched.
- **Typing into a live Codex: text and Enter in one write is read as a paste**,
  and the Enter becomes a newline. The wake line is typed into a shell, so it
  is not affected; anything typed into Codex itself would be.
