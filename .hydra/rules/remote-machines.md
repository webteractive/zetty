---
paths:
    - "Sources/ZettyCore/Remote/**"
    - "App/Sources/App/Remote/**"
triggers:
    - "changing remote machines, serving or the Tailscale check"
---

# Remote machines (other Macs over Tailscale)

> This file is authoritative: edit it here, then run `hydra sync`. The design
> (all phases) is `docs/superpowers/specs/2026-11-01-remote-machines-design.md`,
> which is gitignored, so it exists only on Glen's machine.

Phase 1 ("See"): a Mac with `zetty-serve` publishes its workspace
to the user's other Macs, and a Mac with `zetty-remote-machines` lists them in
the sidebar under **This Mac**. Remote rows can't be dragged, dropped on or
pinned.

Phase 2 ("Type"): clicking a remote project opens it in the window.
`RemoteProjectController` draws its tabs and splits, and each pane runs a
`zetty attach <address>:<pane>` relay to that Mac. The viewer's tab and pane
are its own, kept in memory per `machineStableID/projectID`, and nothing on
the serving Mac moves. Editing the workspace from here (new tabs, splits,
closing, renaming, reordering) is not part of phase 2.

## Anti-goals: break one and the feature is wrong even if it "works"

- **Never block main on the network or the CLI.** `tailscale status/whois`
  run on the monitor's queue or a concurrent whois queue. Sockets live on
  `co.webteractive.zetty.remote-server` / `.remote-client`. Main only ever
  receives `async` hops. No `main.sync`, anywhere. (`RemoteServer.stop` waits
  up to 1s for its listening fds to close. That is the one bounded wait, and
  it is what lets serving switched off and on rebind the same address.)
- **Never listen outside Tailscale.** Bind each of this Mac's own Tailscale
  addresses exactly. Never `INADDR_ANY`, and IPv6 listeners set `IPV6_V6ONLY`.
  With Tailscale stopped there is no address, so nothing listens. Check it
  with `lsof -nP -iTCP:47391 -sTCP:LISTEN`: there must be no `*:47391`.
- **Never a modal.** Every failure has a place to show: a machine header
  ("offline · seen 2h ago", "needs update", a refusal reason), the status
  line in Settings → General → Other Macs, a remote pane's own `[…]` line, or
  the remote view's placeholder.
- **Remote surfaces never enter `WorkspaceModel`.** They live in
  `RemoteProjectController`'s own `SurfaceRegistry`, with fresh UUIDs from
  `RemoteSurfaceIDs`, so no local save, prune, reap, hibernate or zmx call
  can ever see one. The local project stays selected underneath.
- **Nothing aimed at this Mac's project acts while a remote one shows.** The
  menu items in `unavailableWhileRemote` validate to disabled, and
  `KeyInterceptor` beeps their chords itself, because a disabled key
  equivalent falls through to the remote terminal as a keystroke. The prefix
  keys go through `RemoteModeBindings`. Actions the palette reaches directly
  (`closeTab`, `removeProject`, the splits, break pane, `closePane`, `newTab`)
  guard themselves, and the palette builds a remote list
  (`RemoteModeBindings.paletteEntries`). A palette that still listed this
  Mac's tabs let ⌘K → Go to Tab, then ⌘W, close a hidden local tab in the
  isolated test app (2026-11-04).
- **A remote pane never runs anything but its relay.** A surface with no
  command gets ghostty's default, this Mac's own login shell, so
  `RemoteAttachTarget.paneCommand` answers `/usr/bin/false` for a target it
  refuses, and the controller never returns nil. The command runs through
  login and `bash -c`, and its pane id and address come from the peer, so
  `relayCommand` accepts only a hex pane id, a numeric tailnet IPv4 and a
  space-free executable. Remote surfaces start in `/`; the peer's directory
  is only a label.

## Who may connect

`PeerAdmission.decide` checks in this order: no node from `whois` (unknown),
then **tagged**, then **another user**, then **not macOS**. Tagged comes
before the user check because a tagged node belongs to the tag, not to a
person, so "isn't signed in as you" would be the wrong explanation. The server
runs `whois` on every connection *before reading anything*, and answers a
refusal with a `refused` frame and a close. The client never dials a node it
would refuse. Tagged Macs are still listed, with the refusal as their summary.
Other people's Macs are only counted, in the Settings status line.

## Wire and limits

- Port **47391** (`RemoteProtocol.port`). A frame is a 4-byte big-endian
  length, then JSON (`RemoteMessage`: `hello`, `snapshot`, `refused`,
  `attached`).
- A frame over **8 MiB** closes the connection before its body is read.
- Each side sends `hello` first. The server waits 5s for the client's, then
  closes. Another `protocolVersion` keeps the connection open with no
  snapshots, and the client shows "needs update". Bump
  `RemoteProtocol.version` only for an incompatible message change.
- The server drops a feed peer with more than 8 frames queued (a slow or
  dead reader), and accepts at most 64 connections, since each one costs a
  `whois` process and every open remote pane is its own connection.
- Snapshots are `StatusSnapshot` (the `zetty status` model), offered from
  the end of `refreshSidebar()` and paced by `SnapshotThrottle` to **one a
  second**, the last one always delivered. The coalesced chrome refresh alone
  is not enough: a running agent retitles its pane ~10 times a second, and
  each snapshot reads a file per pane on main. A snapshot is built only when
  one is sent, and only if it differs from the last.
- The client dials a node's first IPv4 with a 3s connect timeout and TCP
  keepalive (10s idle, 3s × 2 probes), so a Mac that sleeps without a FIN
  goes offline in about 16s. It retries a drop after 5, 10, 30, then 60s, and
  the backoff resets on the next snapshot.
- `TailscaleMonitor` polls every 10s, and only while one of the two keys is on.

## Terminal connections (phase 2)

- **Handshake.** The relay dials the same port and sends a `hello` carrying
  `attach` (`RemoteAttachRequest`: pane, rows, cols, scrollback). The server
  runs `whois` and admission first, as for a feed. Then it checks the pane
  id (1 to 8 lowercase hex) and asks `RemoteTerminalHost` for a plan. The
  plan is a pty running `zmx attach` on the pane's existing session, after
  `zmx history --vt` when scrollback was asked for. It answers `attached`,
  and from then on the connection carries only `TerminalFrame`s. The relay
  waits up to 10s (`RemoteProtocol.attachTimeout`) for that answer.
- **It never creates a session.** A preserved pane that isn't running yet
  (a background tab never shown) is started offscreen on the serving Mac,
  and the host waits up to 3s for its session. The serving Mac's view
  doesn't change.
- **Frames.** One kind byte (0 data, 1 resize as two big-endian `UInt16`
  rows then cols, 2 ended with a plain-words reason), a 4-byte big-endian
  length, then the payload. A frame over **1 MiB**
  (`RemoteProtocol.maxTerminalChunk`) closes the connection.
- **Backpressure, not dropping.** Above **512 KiB** queued for the relay,
  the server stops reading that pane's pty, and it resumes below
  **128 KiB**. Terminal connections are exempt from the feed's 8-frame drop,
  so a `cat` of a huge file arrives whole and slowly.
- **Refusals**, each shown in the pane as `[…]` and not retried: not a pane
  id; the Mac isn't set up to open panes; that pane is gone; the project is
  hibernated; its project doesn't keep sessions; zmx isn't installed; the
  session didn't start; the Mac is shutting down; couldn't start the pane.
  Another protocol version says to update both Macs.
- **Reconnects.** A failed connect or a drop retries after 1, 2, 5, then
  10s, and says so once in the pane. Scrollback is asked for only before
  the first successful attach, so a reconnect never duplicates it.
- **Sizes.** zmx gives the session to whichever client typed last (below),
  so the serving Mac's pane takes the viewer's size at the first keystroke.
  When a relay detaches, `RemoteTerminalHost.detached` sends SIGWINCH to
  that session's own `zmx attach` clients, which puts the local size back.
- **The viewer's tree is bounded.** `PaneLayout.surfaceTree` drops
  malformed and repeated pane ids, shows at most `maxRemotePanes` (16) per
  tab, clamps ratios to 0.05–0.95 (0.5 when not finite), and lays out a tab
  without a usable layout as a row, built without recursion. A 5,000-pane
  tab crashed the test run before that.
- **Relays only while the feed is online.** `markDisconnected` forgets the
  address, and the controller shows "<Mac> is offline" instead of dialling
  a cached one. The relay doesn't verify the serving Mac's identity itself;
  it relies on dialling only the address the admitted feed is connected to.
- **Teardown order.** Closing a remote pane, leaving the project or the Mac
  going away first kills that pane's relay (`RelayProcesses` finds it
  among this app's descendants by exact argv), then drains the mailbox,
  then prunes. That is the order in `surfaces-and-memory.md`. The argv to
  look for comes from `RelayTargets`, recorded when the surface's command
  was built, never from the machine's current address: going offline
  clears that address first, and rebuilding the argv from it once left
  every relay running after the Mac went away.
- **Project ids survive a relaunch.** A remote view finds its project by
  `StatusSnapshot.Project.id`, so `SessionSnapshot` saves and restores
  each project's id. They used to be regenerated at launch, and every
  viewer showed "<project> isn't open on <Mac> any more" after the
  serving Mac restarted (`projectIDsSurviveARelaunch`).
- **Not yet for remote panes:** copy mode, needs-attention alerts and
  broadcast. While a remote project shows, the palette offers only its
  navigation, and divider drags stay in this view (`onRatioChange` isn't
  wired).

## Which Macs are listed

A Mac becomes a sidebar group only once it has answered a hello. Until then,
a same-user Mac that runs no Zetty, or doesn't serve, is just dialled with
backoff and never shown. `RemoteRoster.reconcile` keeps the known ones honest
against Tailscale. It also lists **tagged** Macs with their refusal, because
the spec says a refusal must explain itself rather than leave a Mac missing.
"Seen N ago" counts from the drop (`RemoteMachine.markDisconnected`), not
from the last snapshot. An idle Mac sends none for hours. With Tailscale not
running, every Mac shows offline, reasons included.

## Cache

`~/.zetty/remote-machines.json`, mode **0600**, because it holds other Macs'
pane titles and directories. It is written at most once per 5s and on quit,
and loaded at launch with every machine offline. A machine that leaves the
tailnet stays listed offline with its last projects. Nothing removes one yet.

## Sidebar

With no machines the outline is exactly the local one: no **This Mac**
header. A machine group collapses while its Mac is offline. A user's
expand/collapse holds until the Mac next goes on- or offline. Remote rows
reuse `ProjectCellView` with `isRemote` (no pin star). Their colors come from
a stable hash of the project id into `ZTheme.projectPalette`, because
snapshots carry no colors. `TerminalViewController.setRemoteMachines` goes
through `setNeedsChromeRefresh`, since a feed can tick as fast as a title.

## Testing

- **Loopback, no Tailscale needed.** A scratch SwiftPM package that depends on
  this repo (`.package(path:)`) and links `ZettyCore`, with copies of
  `App/Sources/App/Remote/*.swift`, can run a real `RemoteServer` on
  `127.0.0.1` / `::1` with a fake `whois`, and a real `RemoteMachinesClient`
  against it. That is how phase 1 was checked: hello, snapshot, refusal,
  version mismatch, hello timeout, oversized frame, slow reader, drop and
  backoff, cache round trip. `listen` is async, so wait briefly before dialling.
- **The isolated test app and the installed app share the tailnet address.**
  Only one can serve, because the second bind fails and is retried only on
  the next Tailscale change. Turn serving off in one of them.
- **Launch the isolated app with `TERM_PROGRAM` set** (`TERM_PROGRAM=zetty-test`
  in the `env -i` line). Without it, Tailscale's GUI CLI fails ("The Tailscale
  GUI failed to start", CLIError error 3), so the test app never sees the
  tailnet and never serves or lists anything.
- **A Mac never admits its own tailnet address**
  (`thisMacsOwnAddressIsNeverAdmitted`). Any local macOS user can reach it,
  so admitting it would let another user on this Mac open this user's
  panes. An end-to-end check of `attach` therefore needs two Macs, or a
  throwaway build that drops the check and is never committed.
- **Watch relays with `pgrep -fl "zetty attach"`.** One per open remote pane,
  gone within about a second of the pane closing on either Mac.
- **Two Macs, both signed in to Tailscale as Glen.** Serve on the mini, show on
  the laptop. Check: the mini's projects and dots appear and update within
  ~1s; `tailscale down` or sleeping the mini gives offline within ~16s and
  online again after; `printf '\xff\xff\xff\xff' | nc <ip> 47391` from the
  mini closes only that connection; a build with another `RemoteProtocol.version`
  reads "needs update"; neither copy on one Mac lists itself.
- Screenshots are TCC-denied in agent sessions, so the sidebar's look needs a
  human.

## Phase 2: zmx with two clients at different sizes

Checked on zmx 0.6.0 (2026-11-03) with two pty clients on one session. The
session takes the size of the client that **typed last**, and zmx keeps each
client's size.

- **Attaching changes nothing.** A new client sees the session at the
  current size until it types.
- **Typing switches the size** to that client's window.
- **A resize applies only from the client that typed last.** Other clients'
  resizes are stored and used once they type.
- **Detaching keeps the size.** When the client that typed last leaves, the
  session stays at its size until another client resizes or types.

What that means for the relay:
- A pane opened on the laptop shows at the mini's size until the first
  keystroke. Only input switches it, and no byte is harmless to every
  program.
- After the laptop lets go, the mini's pane stays at the laptop's size until
  the mini types or its window resizes. The serving side can fix this by
  re-sending its own size when a remote client detaches.

**SIGWINCH puts it back** (checked 2026-11-04): after the last typist
detaches, `kill -WINCH` on another client's `zmx attach` pid makes zmx apply
that client's size (20×60 back to 40×100). So `RemoteTerminalHost.detached`
signals the session's own attach clients; no view jiggle is needed.

To repeat the check, point `ZMX_DIR` at a short path such as `/tmp/zsz`. A
long scratchpad path fails with "socket directory path is too long".
