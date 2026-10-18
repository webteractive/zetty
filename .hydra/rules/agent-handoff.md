---
paths:
    - "Sources/ZettyCore/Transfer/**"
    - "App/Sources/App/TerminalViewController+AgentHandoff.swift"
commands:
    - "zetty handoff"
triggers:
    - "handing a pane's work to a fresh agent session or another account"
    - "changing /z-handoff, the pane's handoff button, or zetty handoff"
---

# Handing a pane's work to a fresh session

> This file is authoritative: edit it here, then run `hydra sync`.

The pane gutter's hand-off button, `zetty handoff (--pane|--cwd) [--to
<name>]` and the Claude mod's `/z-handoff [account]` all reach
`startAgentHandoff` (`TerminalViewController+AgentHandoff.swift`). Glen asked
for it on 2026-10-18: write a temporary handoff markdown, exit to the shell,
start a new session on the same or another account, and have it read the
file. The pure half is `AgentHandoff` and `PendingBrief` in ZettyCore.

It is NOT the hibernation handoff (`hibernation-handoffs.md`), which
compacts the conversation in place and resumes that same conversation on
wake. The two share only the typing helper (`ZmxRunner.submit`).

## Why a file, not a resume

- **Each account keeps its own transcripts**, so another login cannot
  `--resume` this conversation, and a Codex cannot resume a Claude's. The
  brief is plain markdown, which is also what lets the target be either
  harness (Glen chose Claude or Codex). It is written to
  `~/.zetty/transfers/<SURFACE-UUID>.md`: one per pane, so a second handoff
  of the pane replaces it, and outside the project, so nothing lands in git.
  The folder is created `0700`, like the hibernation handoffs' store: a
  brief holds whatever the conversation did, and `~/.zetty` is readable by
  every account on the machine.

## The flow

1. **The agent is asked to write the brief** (`AgentHandoff.writePrompt`, one
   line, because a newline typed into a harness's box submits it
   half-written). From the button or the CLI, Zetty types it with
   `ZmxRunner.submit`: a draft or a question in the box is never typed over,
   and is a refusal; a turn in progress is interrupted only after the GUI
   asked (`confirmInterruptingForHandoff`) or the CLI passed `--force`. From
   `/z-handoff`, the CLI is called with `--self` and answers with the prompt
   as `.text`, and the mod submits it with `$.prompt.submit` 300 ms after
   its command returns. Zetty cannot type into a Claude that is running the
   command that asked: a `/compact` typed there for hibernate sat unsent in
   the box (2026-10-17). A prompt the mod cannot submit calls the handoff
   off with `--cancel`.
2. **A 1 s timer on main waits for the brief** (`checkHandoffBrief`): the file
   is there, non-empty, unchanged since the last tick, and the agent is at
   rest. For Claude that is its hook status not being `running`, since its box
   looks the same while it works. Codex's one hook is turn ended, so its
   screen decides (`PromptBox.readiness == .ready`). A Claude with no hook
   status at all (the isolated test app gets none) needs the file unchanged
   for 5 ticks and its screen at rest. It gives up after
   `AgentHandoff.writeTimeout` (10 minutes) and leaves the agent running.
3. **`relaunchAgent`, the ⟳ restart's body, does the rest** (see
   `agent-pane-refresh.md`): cover, quit line, wait for the old agent to go,
   type `AgentHandoff.launchLine`, uncover once the NEW harness is seen with
   its input drawn below `launchMarker` (the brief's file name, which no line
   above the launch holds). The line is `cd '<cwd>' && <login prefix><harness>
   '<read prompt>'`: both harnesses take a first prompt as an argument. The
   login prefix is `AgentAccountResolver.resumeLogin` with the TARGET as the
   running login, against the shell's spawn account, so the account variable
   is assigned, removed (`env -u`) for a default login, or left alone.
4. **The chip follows the new login** on success
   (`runningAccountID = runningOverride(reported:spawned:)`); the new
   session's own hooks then confirm it. The cached resume session is dropped
   (`forgetResumeSession`): the next ⟳ must not resume the old conversation.
5. **The brief is deleted once the new session's first turn ends**
   (`PendingBrief.observe`, fed from `handleAgentEvents`). Claude reports
   `idle` as it STARTS (its SessionStart hook), before reading anything, so
   only an `idle` after a `running` counts there; Codex's first `idle` is its
   first turn ending. The old session's events are ignored: its `ended`
   mid-relaunch, and anything carrying its session id
   (`handoffOldSessions`). A brief nobody read (no hooks, a failed relaunch)
   is swept at launch and at the next handoff after
   `AgentHandoff.staleAfter` (a day).

## Gotchas

- **The CLI takes a fresh foreground reading** (`ControlRequest
  .takesForegroundReading`). The cached map stops updating while Zetty is
  not frontmost, and a background `zetty handoff` answered "No Claude or Codex
  is running in this pane" for a pane with Claude in it (caught in the
  isolated test app, 2026-10-18).
- **The CLI types the request before it answers** (a slow verb in
  `AppDelegate`'s socket-queue switch). Answering first said "handing off"
  with exit 0 for a pane whose box held a draft; the refusal then only
  reached a sheet in the app.
- **The quit line must reach the harness as a line, then an Enter.** The
  first Codex-to-Claude handoff left `/quit` unsent in Codex's box; see
  `agent-pane-refresh.md`. With the Enter sent on its own, Codex quit in
  about a second.
- **Target names**: none is the same login; `claude` / `codex` are that
  harness's default login and win over an account of the same name; anything
  else is an account, by handle (`AgentHandoff.handle`, `<harness>-<id>`:
  `claude-devops`), its `claude-<account>` command name, its name or its id.
  An unknown one is an error listing the handles (the rule `--account`
  follows). The handle is built from the id, not the name, so the mod can
  list it from `zetty accounts --json` without Zetty's slug rule, and it
  survives a rename. The gutter menu passes handles and `/z-handoff`'s
  argument hint lists them (read at session start, so an account added
  later shows after the next Claude start).
- **The gutter button is in panes only.** A tile's header has the ⟳ but no
  hand-off yet.

## Verified

In an isolated test app on claude 2.1.302 and codex (2026-10-18): a CLI
handoff on the same login (the brief was written, Claude quit and a new
session came up on it about 45 s after the request, and told back what the
old one had been asked to remember), `/z-handoff codex` from the mod under
change (Codex read the brief and acted on it), Codex back to Claude (after
the quit-line fix), the brief deleted after the
first turn with hook events fed by hand, and refusals for a draft, an
unknown target, a shell pane and a cancel with nothing waiting. Not driven:
the gutter button and its menu (a click could land in Glen's app), and a
handoff to a real second account (the test app has none).
