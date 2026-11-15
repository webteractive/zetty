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
`AgentStatusBoard`: the newest wins, a tie goes to the mod, two empty
foreground probes in a row end the agent (only an idle shell is a miss; a
tool the agent runs is presence; an unprobed pane is decided by reports
alone), and the probe's end outranks every earlier report so a dead agent's
snapshot can't revive the dot. Replay restores quietly and ages a running or
waiting report older than 15 min (from its last confirmation: the mod's
`updatedAt`) to idle; a hook line without `ts` reads as time 0, so it always
ages.

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

**The inbox persists** (`AttentionInboxStore`, `attention-inbox.json` in
Application Support). Nothing syncs it before the startup replay
(`hasReplayedAgentEvents`); the first sync after it (`settleAfterReplay`)
keeps restored entries still waiting, with their read marks — an unread
survivor still badges — and marks a waiting pane the inbox never held as read
(true, but not news).

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
- OSC 9;4 progress → running; a clear → idle **only from running** (Claude
  clears progress when it stops to ask; that must not wipe the yellow).
- OSC 133;D (shell integration, zsh) in a pane with an agent state → ended,
  and the live title is marked stale: the dot clears as the agent exits.
- BEL in an agent pane not in view → the finished banner. Never yellow.
- Only the main registry listens: a remote project's panes (another Mac's)
  never drive this Mac's state. Ghostty rate-limits desktop notifications to
  1/s app-wide (identical ones 5 s), which can drop a second pane's notice;
  hooks and the mod cover Claude.
- **A pane not on screen gets no signals until it is shown**: each pane has
  its own Ghostty controller, ticked only while its view is in the window, so
  a project in the background queues its actions (observed 2026-11-16). Hooks
  and the mod cover those panes.

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
  after a turn, is not "needs you"), Stop→idle, SessionEnd→ended. Every launch
  repairs them (`HookInstaller.repairClaudeHooksEverywhere`) in `~/.claude` and
  each Claude account's directory: a missing event is added and our group's
  matcher corrected, in place; a directory without Zetty's hooks is never
  touched. `isInstalled` stays "any of ours present" (the Settings toggle);
  `needsRepair` is "installed but out of date". Launch writers of
  `settings.json` (mod sync, repair, account installs) share one serial queue.
- **Codex** — chains the single `~/.codex/config.toml` `notify` (emits then execs
  your original; uninstall restores it). Only turn-ended fires → idle/presence.
- **Hermes** — `hooks:` block in `~/.hermes/config.yaml` (pre_approval_request→
  needsAttention, pre_llm_call→running, post_llm_call→idle, session start/end). If
  a `hooks:` block already exists, install shows a snippet to merge by hand.

Notes: restart the agent after installing; correlation is by the `surface` field
the hook helper reads from the pane's `ZETTY_SURFACE` (or the `ZETTY_CWD_FILE`
stem for panes created before it), so two panes in one directory light
independently. An event with no surface, or one naming a pane Zetty no longer
has, falls back to matching every pane by `cwd`.
