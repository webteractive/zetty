---
paths:
    - "App/Sources/App/Tiles/ReloadingOverlay.swift"
    - "App/Sources/App/Tiles/RefreshSpinner.swift"
    - "App/Sources/App/Tiles/AgentRestartPresenting.swift"
    - "Sources/ZettyCore/Recovery/AgentResume.swift"
triggers:
    - "changing the pane refresh button or restarting an agent in place"
---

# Refreshing an agent pane

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

`⟳` in a pane's gutter restarts Claude or Codex on its existing conversation.

- **The pane is COVERED and the session is driven from OUTSIDE.** `zmx send`
  writes to a session's PTY whether or not a client is attached, so the quit
  line (`/exit` / `/quit`, `AgentResume.exitCommand`) and then the resume go in
  through `ZmxRunner.send` while a `ReloadingOverlay` hides the churn; the pane
  is uncovered once the agent is back. Two earlier versions were wrong in
  opposite directions: one RESPAWNED the pane, which lost the scrollback
  because a new `Surface` means a new session; the other typed into the visible
  pane with `registry.sendText`, which kept the scrollback but made you watch
  a TUI die.
- **The cover is a CHILD of the terminal view, never a sibling.** libghostty's
  surface is Metal/IOSurface-backed and composites over anything merely beside
  it, whatever the subview order says — the first version added the overlay to
  the pane container and it was simply not seen, so the `/exit` was watched
  being typed while the log reported a clean restart. A child of the surface
  does draw on top; it is the same trick `PathHoverTracker` uses for its
  ⌘-hover underline, which is the one other thing in the app that draws over a
  pane.
- **A frame must draw before anything is sent.** Adding the cover and sending
  in the same run-loop turn races the compositor, and losing that race looks
  identical to having no cover at all. `refreshAgentPane` forces layout and
  hops once through main before the first `zmx send`.
- **Nothing is detached and nothing is FREED, and that distinction is the whole
  reason this shape works.** Tearing a live preserved surface down is
  `ghostty_surface_free`, the call that disabled `free-background-panes-after`
  because it can block the main thread — see that section. Hiding a view costs
  nothing and `zmx send` does not care whether a client is attached, so the
  "detach, restart, reattach" behaviour is reachable without ever calling it.
  Do not "simplify" this into a prune-and-respawn.
- **The wait has TWO phases, and the second is why the overlay can be trusted.**
  Phase one polls until the OLD agent is gone, then sends the resume; phase two
  polls until an agent is back BEFORE uncovering, so the placeholder never
  lifts onto a bare shell. On timeout in either phase nothing further is sent —
  a resume landing in a still-running agent is not a restart, it posts as a
  chat message, the same rule restart recovery follows for a cancelled
  shutdown.
- **A process existing is NOT a harness that has finished resuming**, and
  conflating the two is what made the cover look broken. The probe sees
  `claude` the instant it is exec'd — measured at 0.93s after the resume was
  sent — so uncovering on first sight put the shell still echoing
  `cd … && claude --resume …`, and then the harness's own boot screen, back on
  screen: precisely the churn the cover exists to hide. `agentReadySightings`
  (5 polls, 2.5s of CONTINUOUS presence) is what it waits for instead, which
  also makes it flap-proof. The settle branch returns before the deadline
  check, so it is bounded by its own count rather than able to hang.
- **The exit poll is 0.5s and BOUNDED (20s), deliberately faster than the 3s
  foreground probe.** This is a user-initiated wait, not a standing loop: one
  `ps` per tick until the agent goes, then it stops. Riding the probe instead
  would leave up to three seconds of dead air between the agent quitting and
  the resume being typed.
- **It refuses without preserve-sessions.** Exit is detected from the pane's
  foreground process via its zmx session; with no session there is no way to
  know the agent has gone, and guessing would type the resume into a live
  agent. An alert says so rather than failing silently.
- **`exitCommand` returns nil rather than guessing** for opencode, aider,
  gemini and hermes. A wrong line leaves the agent running with a stray message
  in its prompt — worse than no button.
- **The button needs BOTH halves**: an agent the probe currently sees (something
  to quit) and an id (something to come back to). Requiring only the id would
  offer it on a pane sitting at a shell, where the quit line goes nowhere.
- **`AgentResume` is the ONLY place the grammar lives** — `exitCommand` for the
  way out, `RestartRecovery.resumeCommand` for the way back, and `canRestart`
  requiring both. No separate `supports(_:)` list beside them, which would be a
  second thing to keep in step and would disagree the moment a harness was
  added.
- **The id comes from hooks first, then `AgentSessionLookup` — and the LOOKUP
  IS CACHED, because visibility cannot do filesystem IO.** Hooks name the pane
  exactly but fire only when the agent acts, so hooks alone covered 2 panes in
  11 on the reference workspace; a predicate reading hook state alone leaves the
  button absent from most panes that want it (shipped that way in 2f57b6d and
  fixed straight after). But the lookup reads harness transcripts off disk and
  the predicate runs per visible pane on every coalesced refresh, so resolving
  inline would be a main-thread filesystem scan several times a second — the
  `git` pill's mistake. `lookedUpResumeCommands` is filled off-main, once per
  surface (`resumeLookupAttempted` stops a pane with genuinely no session being
  rescanned), and released when the probe stops seeing an agent there or the
  pane is respawned, so a stale command can never outlive its process. The
  kind comes from the PROBE, never a stored `AgentState.kind`, which can be
  stale from the era when hooks matched by directory and once produced
  `codex resume <claude id>`.
- **It is on the TILE HEADER as well as the pane gutter, and the tile half is
  the one that matters here.** Tile mode replaces the pane area outright, so
  while the grid is up `rootContentView` holds no `LeafContainerView` at all —
  a pass that walks only it finds nothing, which is exactly why the button
  never appeared for a workspace that lives in tile mode (shipped that way in
  72aeb00). `updatePaneRefreshButtons` branches on `tileMode` and drives
  `TileGridView.updateRefreshButtons` instead. In the header it sits leftmost
  of the control cluster, away from `×`: a refresh ends the running agent and
  must not sit under a pointer that just missed close.
- **The button turns accent while a restart is in flight, then flashes the
  outcome.** `RefreshSpinner` (one helper, not a copy per host) tints the `⟳`
  glyph accent — static, NOT rotated: the spin was removed as tacky, and the
  Reloading cover already says the pane is busy — then flashes semantic green
  on a resume that landed or red on a timeout. Accent because accent means
  ACTIVE; the flash because the outcome belongs on the control that was
  pressed, not only in a dialog. A
  covering placeholder was rejected: the pane stays live through the whole
  restart, so a panel over it would hide the agent quitting, the resume being
  typed, AND the scrollback that going in-place exists to preserve.
- **An in-flight button is pinned visible.** The probe stops reporting the agent
  the instant it quits — which is mid-restart — so the ordinary visibility rule
  would hide the control halfway through its own restart. Both the gutter and
  the tile pass therefore OR in `agentRestartTimers[id] != nil`.
- **The button's visibility updates WITHOUT a rebuild.** The gutter is built
  once per `rebuildSurfaceNodeView`, but agents start and stop between
  rebuilds, so it would otherwise appear only after some unrelated structural
  change. `LeafContainerView.setRefreshVisible` is one boolean per visible
  pane, driven from the coalesced chrome refresh — it stays inside the pane's
  own view, exactly as the file tree does, rather than forcing a rebuild.
