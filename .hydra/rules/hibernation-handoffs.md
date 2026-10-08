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

Hibernating a project has each Claude or Codex pane compact its OWN
conversation into a handoff first, in its chat; the project is put away once
they all have, and waking resumes each compacted conversation.
`hibernate-after` reaches projects whose agents are idle. Spec:
`docs/superpowers/specs/2026-10-07-hibernation-handoffs-design.md` (it
describes the first design, a headless fork after an instant hibernate; both
halves were overturned, see below). Pure logic is in `ZettyCore/Hibernation/`;
the app layer is `HandoffCompactor`, `ZmxRunner.compact`, `HandoffStore`,
`HandoffBanner`, `AgentTranscript` and `TerminalViewController+Handoffs.swift`.
Needs `preserve-sessions` (`handoffsEnabled`); without zmx both hibernation and
`hibernate-after` behave as they did before.

## Handoffs first, then the project is put away

- **The order is: stop a turn in progress, have every agent compact, wait
  for all of them, then end the sessions** (Glen, 2026-10-08, overturning the
  spec's "a handoff never blocks the hibernate", which was an assumption
  carried over from Tinker and never his decision). `hibernateProject` only
  STARTS the attempt when there is an agent to ask (`beginHibernation`); the
  old body is `putAway`, reached when `HibernationPreparation` answers
  `.putAway`. With nobody to ask (no agent, `--no-handoff`, handoffs off) it
  is put away at once, as before.
- **Why the other order went.** Put away first and handed off afterwards, a
  wake inside that window silently resumed the old conversation, and a
  handoff that failed was only ever seen later, as a pane waking into a plain
  shell with its agent already gone.
- **Until `putAway` the project is awake**, so the attempt can be called off
  (`cancelHibernation`): typing into it (`noteUserInput`), the banner's
  Cancel, the sidebar toggle, `zetty wake`, a pane added or closed
  (`cancelOutdatedHibernations`, from `reconcileSessions`), and for a
  `hibernate-after` attempt the project being on screen again when the
  agents are done. `zetty send` does not cancel.
- **Cancelling is not undoing.** A chat that has compacted stays compacted,
  and one that is compacting finishes: the work is the harness's, in its own
  pane, and nothing of ours is running to stop. That is the price of doing it
  in the chat, and it applies to `hibernate-after` too: come back mid-way and
  the project stays awake with a summarised conversation.
- **Nothing is on disk until `putAway`.** Records live in
  `HibernationInProgress` and `HandoffStore.save` writes them at the last
  moment, so a quit or a cancel mid-way leaves nothing to sweep.
- **One failure leaves the project awake, at once** (`.leftAwake`), and the
  others stop being waited on. The project is marked `keptAwake`, or
  `hibernate-after` would try again every minute. `handoffFailures` carries
  the pane and the reason for the sidebar tag ("Handoff failed"),
  `HandoffBanner` (Hibernate Anyway puts it away with `.none`; Dismiss) and
  `zetty status` (`‹handoff: failed›`). In memory only; a new attempt clears
  it.
- **The CLI answers at once.** `zetty hibernate` returns `.ok` with the
  project still awake; `status` is how a script follows it. A second
  `hibernate` meanwhile is an error, not a second attempt.
- **The busy rule is unchanged, and now reads oddly.** An idle agent is still
  "busy" to `confirmClosingBusyPanes` and `cliRefusal` (anything but a bare
  shell), so the GUI asks and the CLI wants `--force` before a hibernate that
  will hand the conversation off rather than discard it.
- **The banner's buttons run a turn late** (`DispatchQueue.main.async`):
  each rebuilds the pane area, which removes the banner while its own click
  is still inside it. The same for the cancel on a keystroke.

## The agent compacts its own chat

- **`/compact <instructions>` for Claude, `/compact` for Codex, typed into
  the live pane** (`HandoffCompaction.line`, `ZmxRunner.compact`). Glen asked
  for it on 2026-10-08 in place of the fork: it is visible in the chat, it
  needs no second process and no `-p`, and the compacted conversation IS the
  handoff, so there is no file and nothing for a fresh agent to be pointed
  at. Verified on claude 2.1.294 and codex 0.161.0.
- **The fork is gone, and why it was there is why this needs care.** The spec
  rejected typing into the live pane because it "needs an empty prompt box
  and an idle agent". Both are now handled explicitly, below, rather than
  avoided.
- **A box that holds a draft or a question is never typed over.** The line
  would join the draft, or answer the question. `PromptBox.boxIsEmpty` is
  read first, before anything is sent, and a box that is not empty is a
  failure with that reason: the project stays awake and the person decides.
  Nothing is cleared that somebody typed.
- **Only then is a turn stopped.** Claude panes whose hooks say `running`,
  and a Codex whose screen shows `esc to interrupt`, are sent Escape.
  `needsAttention` is not a reason: it is an idle Claude's notification (box
  empty, nothing to stop) or a real question (box not empty, already a
  failure above).
- **Keys go in the kitty keyboard protocol's encoding.** Both harnesses turn
  it on (`CSI = 5 ; 1 u` shows in Claude's screen). Escape is `CSI 27 u` and
  Ctrl+C is `CSI 99 ; 5 u`; the raw bytes `0x1B` and `0x03` did nothing to
  either. A bare ESC is still tried second, for a harness with it off.
- **An interrupted Claude turn that had printed nothing puts its prompt back
  in the box**, where it looks like a prompt that was never submitted. Since
  the box was seen empty before the interrupt, what is in it afterwards came
  from the interrupt, and that alone is cleared with Ctrl+C. The handoff
  knows nothing of that prompt.
- **Claude's `Stop` hook does not fire on an interrupt**, so nothing waits
  on its status; the screen is read again 1.5 seconds after each key.
- **Text and Enter go in separate writes**, 0.3 seconds apart. Both harnesses
  read them arriving together as a paste and keep the Enter as a newline:
  the line sits in the box, looking sent to nobody.
- **The instructions are one short line.** A newline would submit half of
  it, and Claude folds a long paste into a `[Pasted text]` chip that a slash
  command would take as its whole argument. `HandoffCompactionTests` holds
  the length under 500.
- **Done is read off the transcript, not the screen**
  (`HandoffCompaction.hasCompacted`): Claude appends
  `{"type":"system","subtype":"compact_boundary"}` and Codex
  `{"type":"compacted"}`, as each prints that it is done. Only what the file
  gained since the request is read. Claude's took 8 to 12 seconds on a small
  chat, Codex's about 30.
- **The screen only tells a compaction still running from a harness that
  stopped without one.** Every 5 seconds: no `Compacting…` line near the
  bottom and an empty box, three readings in a row, is "it did not compact".
  The session id stays the same through a compaction in both harnesses, and
  a wrong transcript ends here, as a failure after 15 seconds, not as a
  5-minute wait.
- **A conversation already compact is a handoff already**
  (`HandoffCompaction.needsCompaction`, read off the transcript's tail): its
  last compaction has no agent reply after it. That is a project woken and
  put away again with nothing said in between, and nothing is typed into
  it. Asked anyway, Claude answers "Not enough messages to compact" and
  writes no marker, which read as "it did not compact" and left the project
  awake, the first time a project was hibernated twice. That answer on the
  screen is also taken as done (`PromptBox.saysNothingToCompact`), for
  whatever the transcript check does not foresee. One exchange after a
  compaction IS enough for Claude to compact again.
- **A cleared or brand-new chat is skipped, and skipping is not failing**
  (`HandoffConversation.hasReply`, read off-main). It has a session and
  nothing to compact. The sign is the AGENT having replied: after a `/clear`
  a Claude transcript opens with `user` lines that are the command's own
  output. A fresh Codex writes no rollout until its first message, so it has
  no session at all and never gets this far. A skipped pane gets no record
  and wakes as a plain shell.
- **Every agent pane of a project compacts at once** (Glen, 2026-10-08).
  There was a cap of two, to spare one login's rate limit; a project with
  many agents now spends that many turns together.
- **Nothing to kill at quit.** `HandoffCompactor` only asks and waits. A quit
  mid-way leaves the project awake and nothing on disk; whatever was
  compacting finishes or dies with its session.
- **Without hooks a working Claude is not known to be working.** Its box
  reads empty, so `/compact` is typed while it works and queues behind the
  turn. It still compacts, later, or the five minutes run out.

## Files

- `~/.zetty/handoffs/<SURFACE-UUID>.json` is the record (harness, session id,
  directory, account), one per pane that compacted. Directory `0700`, file
  `0600`, written to a temporary name and renamed. There is no handoff file:
  the handoff is the compacted conversation in the harness's own store.
- **The record exists because the wake needs it after a relaunch.** Nothing
  else says which conversation a hibernated pane had, or under which login.
- **A hibernated pane has no surface to prune**, so closing it or removing its
  project reaches no close hook. Its record is swept in `reconcileSessions` by
  the ownership question the `<uuid>.cwd` files use.

## Waking

- **A pane with a record resumes its conversation; any other is a plain
  shell** (`HandoffWake.plan`). The line is the ordinary resume line with a
  first message (`claude --resume <id> '<wake line>'`, `codex resume <id>
  '<wake line>'`), so the agent says where things stand instead of sitting
  silent. It carries the pane's login like every resume.
- **A project with handoffs wakes as ONE pane, started with the one picked**
  (Glen, 2026-10-08, after two wrong readings: first "choose per pane how it
  comes back", then "tick the ones to resume"). Hibernating hands off every
  agent pane, all at once; waking does not put those panes back.
  `HibernationPlaceholderView` lists the handoffs, and a click on one, on
  a harness's row (a new conversation) or on Standard session calls
  `wakeProject(_:startingWith:)`:
  the layout is collapsed to a single pane (`TabList.collapse`), that pane's
  start is queued, and the ordinary wake follows.
- **Picking looks the same wherever it happens** (Glen, 2026-10-08, off a
  screenshot of a first version that had its own floating rows and pills).
  The hibernated screen and the new-pane sheet both use `ChooserListView`,
  with the row titles and the bin coming from `AgentChooserSheet`
  (`handoffRowTitle`, `standardSessionTitle`), so a second design cannot
  grow beside the first. On the screen the list is clicked, not driven from
  the keyboard (`selectsFirstRow: false`): it never becomes first responder
  there, because its Return and 1–9 would wake a project that viewing must
  never wake.
- **A handoff's title is cleaned in one place** (`HandoffRecord.label`):
  one taken off a pane starts with the glyph its harness draws (`✳ `), one
  taken off the transcript does not, and listed together they read as two
  kinds of thing.
- **The handoffs not picked wait, and belong to the PROJECT.** A record names
  its project and carries the conversation's title, because the pane it
  came from is gone once the layout is collapsed. `HandoffStore.sweep` keeps
  a record while its project exists; ownership by pane, which every other
  per-pane file uses, would delete the waiting ones at the next sweep.
- **A record names its project by `settingsKey`, never by id.** A
  `ProjectRuntime` gets a new id at every launch (the snapshot does not keep
  one), so records filed under an id were all swept as orphans by the next
  launch: three staged handoffs were gone after one restart of the app.
- **They are offered wherever a new pane is made**: `chooseAgentThenSpawn`
  puts them ahead of the agents in `AgentChooserSheet` ("Resume: Claude ·
  …"), for a new tab, a split and a tile alike, and shows the sheet for them
  even with the project's agent prompt off. Picking one spawns the pane on
  the handoff's own login and removes the record. `zetty new-tab` and
  `zetty split` go past the chooser, as they always have.
- **A waiting handoff can be deleted where it is listed** (`deleteHandoff`):
  the bin ending its row on the hibernated screen, and on its row in the
  chooser. Only the record goes; the compacted conversation is the harness's
  and stays in its history, which is why nothing asks first. In the chooser
  the bin is an image, not a button: the row's click recognizer takes the
  mouse-down before a button would, so `rowClicked` tells the two apart by
  where the click landed. Deleting there closes the sheet and asks again
  with what is left, a turn later, since the sheet reporting it is still
  closing.
- **A waiting handoff is `wake == nil`; one on its way back has it set**
  (`HandoffRecord.isWaiting`). `restoreHandoffState` only re-types the
  second kind. Before this distinction every record of an awake project was
  taken for a lost wake line, which would have resumed the whole pool at the
  next launch.
- **A pane woken but never opened is waiting again when its project is put
  away** (`putAway`). A whole-layout wake marks every record as on its way
  back, but a wake line is only typed when its tab is shown. Hibernated
  again first, such a record kept its mark, so it was missing from the list
  on the hibernated screen, and its stale line was still queued for
  whatever that pane was woken as next.
- **A handoff is titled by its conversation, then by its pane.** The
  harness's own title (`HandoffConversation.title`, Claude's `ai-title`)
  names what the record will resume. Where no hook names a pane's session,
  the pane and the conversation matched to it can differ, and a pane's
  title then listed one chat under another's name.
- **A handoff filed under the surviving pane is given a new id**
  (`rekeyed`) unless it is the one picked. Records are filed by the pane
  they came from, and the next hibernation would file that pane's new
  handoff over it.
- **`zetty wake`, and a wake a CLI verb or a tile makes to drive a pane, put
  the whole layout back** (`queueHandoffWakes`), each agent pane resuming
  its own handoff: a script that names a pane expects it to exist.
  `--fresh` and `--shell` apply to every pane alike there
  (`HandoffWake.Choice`, carried beside the wake in `handoffWakeChoices`
  because a wake can be deferred behind a teardown or happen in place).
  `singlePaneWakes` is what tells `queueHandoffWakes` a picked wake has
  already decided.
- **A GUI wake away from that screen shows it rather than deciding**
  (`wakeFromUI`: the sidebar toggle, the palette's Wake Project).
- **Plain shells and split geometry do not survive a picked wake.** A
  project with handoffs comes back as one pane whatever its layout was; one
  with none keeps its layout, as before.
- **This is decision 2 of the spec reversed in form, not in effect.** The
  agent comes back with only the summary in its context, which is what "a
  fresh agent from its handoff" bought, without a second conversation.
- **A pane starting from a handoff is covered until its agent is up**
  (`coverPaneWhileAgentBoots`; Glen, 2026-10-08: "the user should see the
  loading state instead of that command paste"). The start line is long
  (`cd … && claude --resume '…' '<wake line>'`) and was watched being typed
  into a shell. The cover is `ReloadingOverlay`, the refresh button's, with
  its two rules: a CHILD of the terminal view, and lifted only after the
  agent has stayed in the foreground for `agentReadySightings` polls. It
  goes up in `injectStartupCommandIfPending`, before the grace period the
  line waits out, which is what lets a frame draw first. After 30 seconds
  with no agent it lifts anyway, so a line that failed is seen.
- **That cover is held by the view controller, not by the pane's container**
  as the refresh button's is. A wake is followed by rebuilds, each making
  new containers, and a cover whose only reference sat on the old one could
  never be taken down.
- **Which panes get it is said two ways.** `handoffBootSurfaces` names a pane
  that exists when its start is queued (a project woken as one pane, or
  with its whole layout). `handoffBootCommands` names the COMMAND, for a new
  tab or split: the chooser hands the command on before the pane it is for
  has an id, through half a dozen spawn paths. A resume line carries its
  session id, so it cannot be mistaken for another command.
- **Every wake line goes through the guarded startup path**
  (`queueStartupCommands(_:asAgentResume: true)`): it waits `resumeGracePeriod`
  and is dropped when the probe shows an agent in the pane. That guard reads
  `foregroundBySurface`, so hibernating clears the dead panes' entries itself;
  left stale, a scripted hibernate and wake had every line skipped.
- **The record is consumed when the agent is back**: on the first live hook
  event from the pane, or, hooks being optional, a minute after the line is
  queued when a fresh probe reading shows the harness.
- **Until consumed, the record is the only sign that a wake is owed.** At
  launch `restoreHandoffState` re-queues a wake line lost with the quit,
  unless restart recovery already queued a resume for that pane, which
  describes something later and wins.
- **Hibernating forgets a pane's remembered session**
  (`lookedUpResumeSessions`), so the next hibernation looks the conversation
  up afresh.

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
  have every stale conversation compacted in turn. By hand always asks.

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
- **Which panes hold Codex is read at the moment a session ends**
  (`ZmxRunner.stopCodexTerminals(in:)`, `HibernationTeardown.codexSessions`),
  from a bounded `zmx list` and `ps`, never from the probe's map. The plan
  used to name them, and that failed two ways: a closed pane's plan carries
  no reading, so closing a Codex pane left its commands running; and the map
  runs up to three seconds behind, so a Codex that had just started was still
  listed as a shell when its project was hibernated.
- **Every route that ends a pane's session goes through it**: `endSessions`
  (hibernate, and a closed pane whose surface is held) and `kill` (a closed
  pane, a removed project). Closing a pane takes BOTH at once, so the typing
  is serialised by a lock and the second in line reads the screen afresh;
  without it the composer would get `/stop/stop`.
- **A full shutdown asks too** (`killAndWait`: `quit --kill-sessions`,
  `--simulate-restart`, scratch at quit), all panes at once since the quit is
  waiting on it. On the build before, a Codex command survived
  `quit --kill-sessions`; with it the command was gone four seconds later.
  Both were run in an isolated instance (`DEVELOPMENT.md`, "An isolated test
  instance"), the only way to try a quit that ends every session without
  ending the real ones.

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
- **Without hooks, a pane's session is the newest conversation in its
  directory.** After a `/clear` that is still the OLD one until the new chat
  has a transcript, so a hookless Claude that was just cleared is looked up
  as the conversation it cleared: the request is typed into the new chat,
  and the old transcript never gains a marker, so it fails as "it did not
  compact". With hooks or the mod the new session is named, found empty, and
  skipped.
- **The banner and the "Handoff failed" tag were never seen on screen** by
  the session that built them: the flow was driven through the CLI in an
  isolated instance, where `zetty status` and the log showed every state.
  Nor was the window's minimum width measured with the strip up; its label
  yields (`.defaultLow`) and its buttons do not, as in `CloneWarningBanner`.
- **The hibernated screen's list and the chooser's handoff rows were not
  seen or clicked by the session that built them**: nothing selects a
  hibernated project, or opens the chooser, from the CLI. Glen checked them
  by hand in an isolated instance.
- **Claude's interrupt was tested as a key, not as a path.** Hooks do not
  reach an isolated instance, so `midTurn` was never true there; the
  encoded Escape was sent by hand and stopped a working Claude. Codex's
  interrupt ran end to end.
- **A harness that renames `/compact`, or rewords its transcript marker,
  silently stops handing off**, and every hibernate of an agent project then
  fails after 15 seconds.
- **Typing into a live Codex: text and Enter in one write is read as a paste**,
  and the Enter becomes a newline. The wake line is typed into a shell, so it
  is not affected; anything typed into Codex itself would be.
