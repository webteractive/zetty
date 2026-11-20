---
paths:
    - "Sources/ZettyCore/Model/TabTitle.swift"
    - "Sources/ZettyCore/Session/ForegroundProcess.swift"
    - "Sources/ZettyCore/Agents/*ForegroundProcessProbe.swift"
    - "App/Sources/App/AgentIcons.swift"
    - "App/Resources/AgentLogos/**"
triggers:
    - "changing tab titles, tool logos, or the foreground-process probe"
    - "adding a bundled logo for a tool"
---

# Tab identity (logos and titles)

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

Tab pills and sidebar tab rows show **what each pane is running**: a tool logo
(when bundled) plus the title the CLI emits. Precedence (`TabTitle.display`):
manual rename → agent identity (logo, or a `"claude code: <emitted>"` text
prefix when no logo ships) → emitted title (bare shell names are ignored) →
pwd basename → positional.

- **Identity comes from a foreground-process probe**, not hooks: every 3s
  while the window is on screen (`occlusionState.contains(.visible)`, not
  only while Zetty is the active app — identity froze behind another app)
  one `zmx list` (2 s timeout, `sessionPIDsIfListed`) maps sessions→pids and one
  `ps -axo pid,pgid,stat,tty,command` snapshot finds each session TTY's
  foreground process-group leader (`ForegroundProcess`, pure/tested).
  Interpreter-run CLIs resolve to the script (`python3 …/hermes` → `hermes`);
  a bare interpreter REPL keeps its own name. Requires zmx sessions; without
  them identity falls back to hook-detected agent kind.
- **Sessions `zmx list` misses still get probed**: every wanted session it
  left out takes its shell pid from its daemon in the same `ps` snapshot
  (`SessionPersistence.sessionPIDs(listed:daemons:wanted:)`), which covers
  sessions of another zmx version (0.6.0, Homebrew). A probe with no answer
  (zmx or ps failed or timed out) keeps the last map for one tick, then
  clears it, so panes fall back to reports rather than a stale identity; an
  empty but successful answer clears it at once. Each tick also feeds the
  status board (`observeForeground`): two empty readings in a row end an
  agent that died without reporting (`agent-detection.md`).
- **Agent titles lose their status glyph** (`TabTitle.strippingStatusGlyph`:
  braille spinner frames U+2800–U+28FF, `◐◓◑◒`, `✢✳✶✻✽·` and the space
  after; a glyph-only title is kept). Done in `displayTitle` and before
  `persistTitle` writes `lastTitle`, for panes with an agent identity only;
  the running indicator is the status dot, not the agent's spinner. A title
  that arrived before the probe identified the agent is persisted again when
  the identity appears, and a pane that isn't live has its saved title
  cleaned the same way, so a relaunch never shows a frame frozen mid-spin.
- **A stale live title stays hidden until it changes.** `markTitleStale`
  (probe saw the tool go idle) records the live title in
  `suppressedLiveTitles`; Ghostty never resets a title, so `displayTitle`
  ignores the terminal's title while it still equals that one, and
  `onTitleChange` (which also fires for cwd changes) un-stales the pane only
  when the title actually differs. After two failed probes clear the
  readings, the next good one compares against the readings from before
  the failure (`foregroundBeforeProbeFailure`); against nothing, every idle
  pane looked "just idle" and lost its title.
- **Logos** live in `App/Resources/AgentLogos/agent-<command>.svg` — monochrome
  SVGs from simple-icons (CC0) / lobe-icons (MIT), loaded as template images
  and tinted to match the row's text (`AgentIcons`). Agents also have glyph
  fallbacks; unknown tools just show their emitted title. Add a tool by
  dropping in `agent-<foreground-command>.svg`.
- **Tuist gotcha:** after changing files under `App/Resources/`, `tuist
  generate` can fail with a bogus `Manifest not found at …/AgentLogos` *and
  delete the xcodeproj* (a later build then silently reuses a stale app). Run
  `mise exec -- tuist clean` first, then generate.
