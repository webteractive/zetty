---
paths:
    - "Sources/ZettyCore/Agents/**"
    - "App/Sources/App/AgentEventWatcher.swift"
    - "App/Sources/App/HookInstaller.swift"
triggers:
    - "changing agent status dots, hooks, or needs-attention notifications"
---

# AI agent detection

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

Zetty surfaces running AI agents as **status dots** in the sidebar (per-tab
dots + a per-project roll-up on the diamond): **green = running, yellow =
needs-attention, dim = idle**, plus **red = the last turn failed**, which is
NOT a hook state — it is `AgentStatus.errored`, produced only by
`AgentStatus.displayed` from the Claude Code mod's snapshot (see
`claude-mod.md`). Every dot reads `displayedStatus(for:)`, never
`agentDetector` directly. The engine is pure/tested in `ZettyCore`
(`AgentRegistry`, `AgentStateMachine`, `AgentDetector`, `AgentEvent`).
Reports drive the **status dots only** — tab names/logos come from the
foreground-process probe (see "Tab identity" above). At startup the existing
event log replays once (`AgentEventReplay`: last event per cwd+agent, `ended`
drops) so dots recover for agents already running inside preserved sessions.

**Status model** (spec `docs/superpowers/specs/2026-11-14-agent-status-signals-design.md`):
every source is a timestamped `AgentReport` (hook line `ts`, the mod's
`turn.at`, terminal signals stamped on receipt) folded per pane by
`AgentStatusBoard`: the newest wins (no report counts as newer than its
arrival: a future `ts` or `turn.at` pinned the pane until its agent exited;
native security review of v0.1.62..475736a), a tie goes to the mod, a hook or mod
"needs you" also beats a terminal signal stamped up to 1 s after it
(`terminalStampSlack`: Claude clears its progress as it stops to ask, and that
clear, stamped on arrival, hid the prompt; release review 2026-11-20), two empty
foreground probes in a row end the agent (only an idle shell is a miss; a
tool the agent runs is presence; an unprobed pane is decided by reports
alone), and the probe's end outranks every earlier report so a dead agent's
snapshot can't revive the dot. **A waiting pane stays waiting until the loop
that asked moves on**: tool and permission events carry `loop` (`main` or the
subagent's `agent_id`, from the hook payload or the mod), and a parallel
subagent's tool call doesn't resolve another loop's prompt; a report with no
loop (a new prompt, a turn's end, an older helper) speaks for the whole pane.
Replay restores quietly. A running or waiting report older than 15 min (from
its last confirmation: the mod's `updatedAt`) waits for the first probe: an
agent still in the foreground keeps it (a prompt left over lunch is still
pending, and the install relaunch must not dim it), an unprobed pane ages it
to idle, and the gate ends a dead one. A hook line without `ts` reads as time
0 and ages at once; so does an older mod's snapshot without `turn.at`, which
never beats a hook's report.

**Needs-attention notifications** (config-gated, Settings ⌘, → Agents):
"needs you" = blocked on a decision (permission or question; Glen
2026-11-15). `notify-sound` plays a sound; `notify-badge` badges the Dock icon
with the unread attention-pane count; `notify-system` posts a macOS
notification **whenever the pane isn't in view** (`isPaneInView`: Zetty active,
window key, the pane drawn in the selected tab — only the zoomed one while
zoomed — or a tile on screen), clicking it focuses the pane. `willPresent`
shows agent banners (userInfo `pane`) while Zetty is active; others keep the
system default. Raised on every needsAttention report the board accepts
outside a 2 s collapse window (`raisedAttention`), so a repeat request in a
yellow pane notifies and reopens its inbox entry; replay never notifies. A
**finished turn** (running → idle, `finished`) posts a banner only — no sound,
badge or bell entry.

The probe stamps an agent's end with the time `ps` ran, not when main got
round to it, and runs one tick at a time (`foregroundPollInFlight`), so a slow
zmx can't count two misses a second apart. Each tick also prunes per-pane
state (board entries, folder stamps, stale titles) for panes that are gone,
and the inbox and badge are recounted only when a result moved a status or
raised attention, or the set of live panes changed. **Only awake projects'
panes can be waiting** (`AttentionInbox.waitingPanes`): hibernating a waiting
project, or a replay into one at launch, kept the bell and the Dock badge
counting it. Hibernating recounts at once, since the tick's prune waits for
the window to be visible. A failed turn's banner reuses the pane's "finished"
notification identifier, so it replaces a "finished" posted for the same
moment instead of adding a second banner.

**The inbox persists** (`AttentionInboxStore`, `attention-inbox.json` in
Application Support). Nothing syncs it before the startup replay
(`hasReplayedAgentEvents`); the first sync after it (`settleAfterReplay`)
keeps restored entries still waiting, with their read marks — an unread
survivor still badges — and marks a waiting pane the inbox never held as read
(true, but not news), unless a live report raised it while the replay was
still running (`raisedBeforeReplay`).

**Terminal signals** (live, local panes; spec section 7): each terminal
view's delegate is a `TerminalDelegateProxy` that forwards to its
`TerminalViewState` and raises `SurfaceRegistry.onTerminalSignal`
(`TerminalSignal`), handled by `handleTerminalSignal`, reports stamped on
receipt with source `.terminal`:
- OSC 9 / 777 notification → `TerminalNotification.classify`: Claude →
  nothing (the mod and hooks label its notices); otherwise a text starting
  with a Codex decision prefix (`Approval requested`, `Codex wants to edit`,
  `Question requested`, `Implement this plan?`, from Codex 0.157.1's binary)
  → needsAttention; anything else → idle plus the finished banner.
- OSC 9;4 progress → running; a clear → idle only from running; **neither
  moves a pane out of needs-you** (`TerminalProgressPolicy`: Claude may clear
  or re-send progress while it waits to ask).
- OSC 133;D (shell integration, zsh) in a pane with an agent state → ended,
  and the live title is marked stale: the dot clears as the agent exits.
- OSC 9;4 pause (state 4) reports nothing; set, error and indeterminate are
  running, remove is done.
- BEL in an agent pane not in view → the finished banner. Never yellow.
- Only the main registry listens: a remote project's panes (another Mac's)
  never drive this Mac's state. Ghostty rate-limits desktop notifications to
  1/s app-wide (identical ones 5 s), which can drop a second pane's notice;
  hooks and the mod cover Claude.
- **Every live pane's mailbox is drained on the 3 s tick**
  (`drainMailboxes`), visible or not. libghostty-spm ticks a pane only while
  its view is attached and the app is active, so a pane in another project
  (or every pane, with Zetty in the background) queued its actions and
  delivered the backlog stamped as new when shown (observed 2026-11-16).
  Signals from a hidden pane now arrive at most one tick late. **A drained
  "command finished" is stamped with the previous drain's time**
  (`drainedSignalStamp`), the earliest it can have happened: stamped on
  delivery it outranked the SessionStart of the agent started after it and
  ended its dot (release review, 2026-11-20). Every other signal keeps its
  delivery time: stamped early, a Codex decision lost to the key that
  answered the one before, and a tick's signals tied (review of 70c34a5).

Detection is **hook-driven** — libghostty exposes no PTY fd / child PID, so
harness hooks *ping* Zetty:

1. **Settings (⌘,) → Agent Status Hooks** — a toggle per harness installs a
   shared hook helper (`~/.zetty/hooks/zetty-hook.py`) and registers it in the
   harness config (toggle off to uninstall).
2. On a lifecycle event the harness runs the helper, which appends
   `{cwd, agent, event, ts}` to `~/.zetty/agent-events.jsonl` (`ts` is
   `time.time()`, epoch seconds with a fraction, so the hook and the mod's
   report of the same moment order; a line without it parses as time 0, the
   oldest) — plus `surface`,
   `session`, and `config` (the harness's config-dir variable as the hook
   process sees it; that last one drives the account chip, see
   `agent-accounts.md`).
3. `AgentEventWatcher` tails that file; `TerminalViewController` correlates each
   event to panes **by working directory** and drives the dots.

Per-harness install (`HookInstaller` + the pure `*HookConfig` transforms):
- **Claude** — additive hooks in `~/.claude/settings.json` (`ClaudeHookConfig.events`):
  SessionStart→idle, UserPromptSubmit/PreToolUse/PostToolUse→running,
  PermissionRequest→needsAttention, Notification→needsAttention **with matcher
  `permission_prompt|elicitation_dialog`** (decisions only: `idle_prompt`, ~60 s
  after a turn, is not "needs you"; the helper also drops a non-decision
  Notification itself, which covers sessions that loaded the old unfiltered
  hook), Stop→idle, SessionEnd→ended. Every launch
  repairs them (`HookInstaller.repairClaudeHooksEverywhere`) in `~/.claude` and
  each Claude account's directory: a missing event is added and our group's
  matcher corrected, in place; a directory without Zetty's hooks is never
  touched. `isInstalled` stays "any of ours present" (the Settings toggle);
  `needsRepair` is "installed but out of date". Launch writers of
  `settings.json` (mod sync, repair, account installs) share one serial queue.
  Every write to a user's own config (`settings.json` from hook repair, the
  mod's plugin-dir sync and account seeding, Codex `config.toml`, Hermes
  `config.yaml`) goes through `LinkPreservingWrite`: through a symlink
  to the real file, keeping its permissions. A relative link resolves from
  its folder's real location, as the kernel does (with `~/.claude` itself a
  link, a string `..` wrote to an unrelated file), and a loop of links fails
  rather than losing a link. A plain atomic write replaced a
  `settings.json` linked in from a dotfiles repo with a regular file, at
  launch, unasked (release review, 2026-11-20).
- **Codex** — chains the single `~/.codex/config.toml` `notify` (emits then execs
  your original; uninstall restores it). Only turn-ended fires → idle/presence,
  and Codex 0.157.1 sends no progress, so **a key typed into a waiting Codex
  pane moves it to running** (`PromptAnswerPolicy`, `keyReachedFocusedPane`):
  the key is the answer, and the pane otherwise stayed yellow until the turn
  ended. Only a key the terminal itself takes counts: not a ⌘ chord (⌘C
  copying the command to approve turned it green), nor a key typed into the
  sidebar or file tree.
- **Hermes** — `hooks:` block in `~/.hermes/config.yaml` (pre_approval_request→
  needsAttention, pre_llm_call→running, post_llm_call→idle, session start/end). If
  a `hooks:` block already exists, install shows a snippet to merge by hand.

Notes: restart the agent after installing; correlation is by the `surface` field
the hook helper reads from the pane's `ZETTY_SURFACE` (or the `ZETTY_CWD_FILE`
stem for panes created before it), so two panes in one directory light
independently. An event with no surface, or one naming a pane Zetty no longer
has, falls back to matching every pane by `cwd`.
