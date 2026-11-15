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
Hooks drive the **status dots only** — tab names/logos come from the
foreground-process probe (see "Tab identity" above). At startup the existing
event log replays once (`AgentEventReplay`: last event per cwd+agent, `ended`
drops) so dots recover for agents already running inside preserved sessions.

**Needs-attention notifications** (config-gated, Settings ⌘, → Agents):
`notify-sound` plays a sound; `notify-badge` badges the Dock icon with the
attention-pane count (auto-clears when the agent resumes); `notify-system`
posts a macOS notification while Zetty is in the background — clicking it
focuses the pane. Fired on the *transition into* needsAttention; the startup
replay never notifies (stale state).

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
