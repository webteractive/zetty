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
> and the built-in Tailscale node is
> `docs/superpowers/specs/2026-11-10-built-in-tailscale-design.md`; both are
> gitignored, so they exist only on Glen's machine.

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

- **Never block main on the network or the node.** Every call into the
  Tailscale bridge (start, status, whois, dial, accept) runs on `Tailnet`'s
  queues or threads, the server's concurrent whois queue, or the control
  socket's remote queue. Sockets live on `co.webteractive.zetty.remote-server`
  / `.remote-client`. Main only ever receives `async` hops. No `main.sync`,
  anywhere: the control socket reads the client through a `LockedBox`.
- **Never listen outside Tailscale.** The server listens only through Zetty's
  own node (`Tailnet.listen`, port 47391 on the node's tailnet address).
  Nothing binds this Mac's interfaces: `lsof -nP -iTCP:47391 -sTCP:LISTEN`
  shows nothing at all.
- **Never a modal.** Every failure has a place to show: a machine header
  ("offline · seen 2h ago", "needs update", a refusal reason), the status
  line in Settings → Remote, a remote pane's own `[…]` line, or
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

## The built-in node (`Tailnet`, `Bridge/tailnet`)

Since 0.1.62 every Zetty joins the tailnet as **its own device** through
Tailscale's embeddable node (tsnet), whether or not the Tailscale app is
installed or running. The Tailscale app is never touched or needed.

- **The bridge** is our own Go module over `tailscale.com/tsnet`, built as a
  C archive by `scripts/build-tailnet-bridge.sh` (an Xcode pre-build phase;
  universal for releases) and imported as `ZettyTailnet`. Connections cross
  into Swift as **file descriptors**: one end of a socketpair the bridge
  splices to the tsnet connection, so the server, client and relay keep their
  fd code. It is built with `ts_omit_peerapiserver`: on macOS, tsnet's peer
  API otherwise opens a TCP listener on **every interface** (`*:<port>`, found
  2026-11-10 with `lsof -a -p <pid> -iTCP -sTCP:LISTEN`), and Zetty needs none
  of it (Taildrop, peer DNS). Its WireGuard UDP socket is the only other
  socket, as for any Tailscale client. It is also built with
  `ts_omit_logtail`: `TS_NO_LOGS_NO_SUPPORT` alone only stubs the upload,
  and the uploader's buffer file under Caches still held the sign-in link
  while signed out (final review, 2026-11-10). It sets `TS_NO_LOGS_NO_SUPPORT` too, and
  netstack keepalive 10s/3s (a vanished viewer is dropped in under a minute;
  gVisor's outgoing conns expose no keepalive, so the viewer's side relies on
  the feed heartbeat under Wire and limits). Those three
  variables are set by `zt_prepare_env`, called from `main.swift` before any
  pane exists, never by `zt_start`: setting them while panes exist crashed
  the laptop in `ghostty_surface_new` (`surfaces-and-memory.md`, 2026-11-13).
- **State lives in the login Keychain** (`TailnetStateStore`: service
  `co.webteractive.zetty.tailscale-state`, account `<home> @ <hardware UUID>`
  from `RemoteMachineID.stateAccount`, so the isolated test app has its own
  and a Keychain migrated to another Mac never hands it this Mac's device),
  never a file: Lima and Colima mount the home folder into VMs, and whoever
  holds the node key *is* this Zetty. An ad-hoc build is asked once at
  launch; a Developer ID build (releases, `scripts/build.sh`) is asked once
  and then keeps "Always Allow". An **unreadable** item (locked Keychain over SSH,
  a denied prompt) stops the node with the reason in Settings: starting
  empty would enroll a second device. **No failed start is tried again on
  every config reload** (`TailnetLifecycle.failed`), which would read the
  Keychain (and maybe prompt) and post "Other Macs stopped" each time: only
  after **Try Again** (shown in Settings → Remote while the node is `.failed`;
  `TailnetLifecycle.retry` → `Tailnet.retry`), Other Macs turned off and on,
  or Sign Out. Try Again starts a node that failed to start, and restarts one
  that runs but reports an error (it shows `.failed` too). It acts only while
  the state is still `.failed`, so a double-click queued behind the first
  click's Keychain prompt doesn't ask again after a Deny. An unreadable saved
  state says to click Sign Out, the only way out of it. Turning it off and on means turning off BOTH switches (Serve
  and Remote Machines), since the node runs while either is on, which the
  old message ("turn Other Macs off and on") did not say. tsnet's non-secret files go
  in `~/Library/Caches/co.webteractive.zetty/tailscale`.
- **Sign-in** is Settings → Remote → **Sign In…**: Tailscale's
  login page in the browser. Every click asks Tailscale again and opens the
  page it sends back (the bridge marks that event `"browse":true`;
  `TailnetState.pageToOpen`), never the URL cached in the state: it expires
  after 7 days, and Tailscale itself decides whether the old one is still
  good. Only an https page on `tailscale.com` is ever opened
  (`TailnetState.loginURL`). Links in Tailscale's log lines are blanked
  before Zetty's log, since "Copy diagnostics" carries it and a sign-in link
  would enroll this Zetty in whoever opens it. **Sign Out** logs a running
  device out and then sets its `zetty-` name again (`signOut` in
  `Bridge/tailnet/node.go`): Tailscale's Logout deletes the signed-in
  profile, and the fresh one has no hostname, so the next sign-in used to
  join under the Mac's own name (`hadefication-mini`), which every other
  Zetty refuses ("isn't a Zetty"). The bridge keeps the latest name (start,
  then each rename) for this. Every node start sets the name too, so a Mac
  already in that state is fixed by turning Other Macs off and on, or
  quitting Zetty. On a node that couldn't start (an unreadable item, a corrupt
  state) it deletes the saved sign-in and starts over as a new device that
  needs a sign-in, which is the reset from Settings. Notifications
  (`TailnetNotifier`) fire on entering needs-sign-in (once Tailscale has a
  page; clicking does what Sign In… does, and the notification never carries
  the link), needs-approval and failed, never repeated while the state holds,
  plus "Signed in to Tailscale" naming the account and device once a sign-in
  finishes (`TailnetSignInWatch`: running after needs-sign-in, a connecting
  step between allowed; a normal start isn't one). It is how a sign-in
  approved on a phone that picked the wrong account gets noticed.
- **Signing in a Mac you aren't at** (the reason both exist: clicking
  through a browser sign-in over a laggy screen share was painful).
  Settings' **Show QR Code…** asks Tailscale for a page the same way Sign
  In… does and shows it as a QR code in an `NSAlert` sheet
  (`TailnetSignInSheet`, `QRCode`) for a phone to scan; the sheet closes
  itself when the state leaves needs-sign-in. It's behind a click, never
  shown by itself: whoever scans it first can sign this Zetty in to their
  own account. The code is drawn dark on light in the scheme's own tokens
  (`bg1` on `fg` in a dark scheme, `fg` on `bg1` in a light one; a
  light-on-dark code scans badly) with the four-module border, whole
  points per module. `zetty remote sign-in [--json]` is the same over SSH:
  answered on the socket's `remoteQueue` (`signInResponder`), since it
  waits up to 10 s for Tailscale's page and the accept queue is serial. The
  app makes the code (`RemoteSignInReport.qr`, rows of "1"/"0"; ZettyCore
  has no QR encoder) and the CLI draws it with half blocks in explicit
  black on bright white (`QRText`), only when stdout is a terminal;
  `--json` drops it. Off, connecting and failed answer an error; signed in
  and waiting for approval say so. Checked 2026-11-11 by decoding with
  Vision: the code over the wire, the code rebuilt from a test pane's
  screen, and the Settings image in a dark and a light scheme all decoded
  to the page Tailscale sent.
- **Bridge errors are per call**: every C call that can fail takes a
  `char **err` and hands back its own error text, so a dial failing on one
  thread never logs another call's error.
- **The device name** is always `zetty-…` (`ZettyDeviceName`): default from
  this Mac's name, edited after the prefix in Settings, kept per Mac in user
  defaults (`ZettyTailnetDeviceName`), never the synced config. A reinstalled
  Mac whose old device still exists gets a suffix in its MagicDNS name
  (`zetty-mac-mini-1.<tailnet>.ts.net`) until the old one expires or is
  removed; the host name Zetty reads stays the one it asked for.
- **Sign Out keeps the machine key**: Tailscale's logout deletes the signed-in
  profile and saves that through the store, so signing in again is the same
  machine. Saves reach the Keychain in order (persisted under the store's
  lock) and are flushed at quit. A failed status read while running keeps the
  last good status, and a running status wins over a stale error, so neither
  tears the server and the kept panes down.
- **The machine ID** (`RemoteMachineID`, `~/.zetty/machine-id`) is in every
  hello. The sidebar keys Macs by it, so signing in again (a new node) stays
  one Mac. The file's second line is the hardware UUID (`MacHardware.uuid`)
  of the Mac it was made on: Migration Assistant or a restore onto another
  Mac makes a new ID there (and the Keychain account differs too), so two
  Macs never share one identity. A clean reinstall or restore on the same
  Mac keeps both. A file without the second line is kept and bound.
- **Test hook:** `ZETTY_TAILSCALE_AUTH_KEY_FILE` (env, trusted) enrolls with
  that auth key as an **ephemeral node with an in-memory store** (no Keychain,
  no file), which leaves the tailnet when it quits. The file must be a regular
  file owned by the user with no group or other bits, not a symlink.
- The pairing key (0.1.60–0.1.61) is gone; its Keychain item
  `co.webteractive.zetty.remote-key` is deleted at launch without a prompt
  (`LAContext.interactionNotAllowed`); one another build made just stays.

## Who may connect

`PeerAdmission.decide` checks in this order: no node from whois (unknown),
**this node itself**, **tagged**, **another user**, **not a Zetty** (its
Tailscale host name doesn't start with `zetty-`), then **not macOS**. The
server asks the node's whois for every connection *before reading anything*
and answers a refusal with a `refused` frame and a close. The client dials
only candidates from the node's own status, and WireGuard binds the dialled
address to that node, so it doesn't whois again.

**The name rule is what keeps a Mac's own Tailscale device out.** Tailscale's
tunnel on macOS is machine-wide: another macOS account, a daemon, a Docker
container or a NAT'd VM on the laptop all reach the tailnet *as the laptop's
Tailscale device*, owned by Glen. Before the pairing key any of them could
attach to a pane and type as Glen (security review, 2026-11-05). Peers can't
see which app made a device (`tailscale whois --json` of the laptop shows only
`Hostname`, `OS` and `Services`; `Hostinfo.App`/`Package` are stripped,
checked 2026-11-10), so the name is the marker. It is the host name a device
reports for itself (`Hostinfo.Hostname`), not its admin-console name. **Known
gap, accepted by Glen:** a process that can set one of his devices' host name
to `zetty-…` (`tailscale set --hostname` through that Mac's Tailscale) gets in.
Otherwise spoofing a Zetty needs enrolling a device with Glen's Tailscale login.

Another Zetty on the same Mac (the isolated test app, a second test copy) is
its own node with its own sign-in, and is admitted like any other. Tagged
Zettys are listed with their refusal; other people's Macs are only counted, in
the Settings status line.

## Wire and limits

- Port **47391** (`RemoteProtocol.port`) on each Zetty's own node. A frame is
  a 4-byte big-endian length, then JSON (`RemoteMessage`: `hello`,
  `snapshot`, `refused`, `attached`). Protocol **5**: the hello carries
  `machineID`; there is no challenge or proof.
- **`ZETTY_REMOTE_PORT` moves the port** (1024–65535, anything else is
  ignored), read once at launch, for serving, dialling and relays alike. Each
  copy has its own node now, so it is rarely needed; it is not a config key on
  purpose: a real pair on different ports would never find each other.
- A frame over **8 MiB** closes the connection before its body is read.
- The server sends `hello` first and waits 5s for the client's, then closes.
  The client answers only after the server's hello. Another `protocolVersion`
  keeps the connection open with no snapshots, and the client shows "needs
  update". Bump `RemoteProtocol.version` only for an incompatible message
  change.
- The server drops a feed peer with more than 8 frames queued (a slow or
  dead reader), and accepts at most 64 connections, since each one costs a
  whois and every open remote pane is its own connection.
- Snapshots are `StatusSnapshot` (the `zetty status` model), offered from
  the end of `refreshSidebar()` and paced by `SnapshotThrottle` to **one a
  second**, the last one always delivered. The coalesced chrome refresh alone
  is not enough: a running agent retitles its pane ~10 times a second, and
  each snapshot reads a file per pane on main. A snapshot is built only when
  one is sent, and only if it differs from the last.
- The client dials a peer node's first IPv4 through the node with a 3s
  timeout. It retries a drop after 5, 10, 30, then 60s, and the backoff
  resets on the next snapshot. Links are socketpair ends, so
  `RemoteProtocol.configureLink` only sets `SO_NOSIGPIPE`; keepalive is the
  bridge's (above).
- **Feed heartbeat** (`FeedLiveness`, hello feature `feed-heartbeat`, no
  protocol bump). The server re-sends its latest snapshot to a feed that has
  had nothing for 15s (checked every 5s), so an idle Mac's frames arrive every
  15–20s. A viewer whose server offered the feature drops a link silent for
  45s and dials again (log: `client: <Mac> sent nothing for 45s`). Before
  this, a link that outlived its serving Mac (a quit and relaunch, a sleep,
  anything the peer's Tailscale status never showed as offline) got no error,
  only silence. The laptop kept the mini "online" with a snapshot two days
  old, missing the projects added since (2026-11-24). An older server, without the
  feature, is never dropped for silence: it sends nothing while unchanged.
  Older viewers just take the resends as snapshots. A resend also fills a
  dead reader's outbox, so the server drops it by the 8-frame limit.
- `Tailnet` refreshes the node's status every 10s and on every state event,
  only while one of the two keys is on.

## Terminal connections (phase 2)

- **The relay can't reach the node** (a separate process), so it asks this
  Mac's app over the control socket: `remote-connect <ip>`. The app dials
  only an **online** Mac's current address, through the node, and hands the
  connected descriptor back with the reply (`FDPassing`, `SCM_RIGHTS`), off
  the serial accept queue. **The app keeps its copy open until the relay
  closes the request socket** (`FDPassing.handOver`, up to 10s): closing it
  right after `sendmsg` ended the connection while the descriptor was in
  flight, so a relay whose process was still starting got a dead socket on
  every first attempt over a relayed link ("can't reach", then fine on the
  retry; found 2026-11-10 with the laptop away from home). A reply starting `couldn't reach ` is retried like
  a drop; any other is a refusal, shown and not retried. With no app the
  relay says "Zetty isn't running on this Mac". Anything that reaches the
  control socket can already `zetty send` into panes, so this widens nothing.
- **Handshake.** The relay sends a `hello` carrying `attach`
  (`RemoteAttachRequest`: pane, rows, cols, scrollback). The server runs whois
  and admission first, as for a feed. Then it checks the pane
  id (1 to 8 lowercase hex) and asks `RemoteTerminalHost` for a plan. The
  plan is a pty running `zmx attach` on the pane's existing session, after
  `zmx history --vt` when scrollback was asked for. It answers `attached`,
  and from then on the connection carries only `TerminalFrame`s. The relay
  waits up to 10s (`RemoteProtocol.attachTimeout`) for that answer.
- **It never creates a session.** A preserved pane that isn't running yet
  (a background tab never shown) is started offscreen on the serving Mac,
  and the host waits up to 3s for its session. The serving Mac's view
  doesn't change. `zmx attach` creates a missing session, so the pty runs
  `RemoteServedAttach`, which checks the session again right before the
  attach and just ends if it is gone: a pane closed or hibernated here
  while a long replay drains would otherwise come back as a bare shell
  (`servedAttachNeverCreatesAMissingSession`). The check is a `zmx history`
  that works (zmx exits 1 for a session that has gone and never creates
  one); only a failure asks `zmx list`, which takes a second per session of
  another zmx version, 4s on the mini (`SessionPersistence.fetchReplay`).
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
  hibernated; its project doesn't keep sessions; Zetty's zmx is missing (a
  damaged bundle); the session runs a zmx that is gone; the session didn't
  start; the Mac is shutting down; couldn't start the pane.
  Another protocol version says to update both Macs.
- **Reconnects.** A failed connect or a drop retries after 1, 2, 5, then
  10s, and says so once in the pane. No hello asks for scrollback: the first
  attach's takeover repaint replays it, and a reconnect never duplicates it.
- **Sizes.** zmx gives the session to whichever client typed last (below).
  The screen in use takes it and is repainted (Taking the size back, below).
  When a relay detaches, `RemoteTerminalHost.detached` sends SIGWINCH to
  that session's own `zmx attach` clients, which puts the local size back.
- **The viewer's tree is bounded.** `PaneLayout.surfaceTree` drops
  malformed and repeated pane ids, shows at most `maxRemotePanes` (16) per
  tab, clamps ratios to 0.05–0.95 (0.5 when not finite), and lays out a tab
  without a usable layout as a row, built without recursion. A 5,000-pane
  tab crashed the test run before that.
- **Relays only while the feed is online.** `markDisconnected` forgets the
  address, and the controller shows "<Mac> is offline" instead of dialling
  a cached one. The app dials a relay only to the address an admitted, online
  feed is connected to.
- **A project left behind stays connected for 30 minutes**
  (`RemotePaneRetention`, `RemoteProjectController.keepShown`). Its surfaces
  stay in the controller's registry, out of view, so coming back re-parents
  them: no new relay, no scrollback replay (the replay frame is what showed
  Home broken until a key, 2026-11-09). Back in view, the focus marker
  claims the size if the other Mac took it meanwhile (the server's
  `sizeMoved` cleared `drives`). A kept project is freed whole when its Mac
  is not online at the address its relays dialled, the project is closed,
  hibernated or empty there, or it was left 30 minutes ago (a 60s timer
  checks); a pane closed there goes on its own. Past 32 kept surfaces
  (~37 MB each) the projects left longest ago go first, whole, and a
  smaller older one never slips in past a bigger newer one. Tabs never
  opened stay unconnected. `setRemoteMachines` feeds the controller every
  machine list (`noteMachines`) after leaving a vanished Mac's view, and
  `showRemoteProject` seeds it before `show`, since a prune against an
  empty list frees everything.
- **Teardown order.** Closing a remote pane, freeing a kept project or the
  Mac going away first kills that pane's relay (`RelayProcesses` finds it
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

A Mac becomes a sidebar group only once it has answered a hello
(`RemoteRoster.adopt`, keyed by its machine ID). Until then, a Zetty that
doesn't serve is just dialled with backoff and never shown.
`RemoteRoster.reconcile` keeps the known ones honest against the node: a
machine whose node has **left the tailnet** (an ended ephemeral test copy, a
device removed in the admin console) is dropped, and **tagged** Zettys are
listed with their refusal, keyed by node until a hello names them, because a
refusal must explain itself rather than leave a Mac missing.
"Seen N ago" counts from the drop (`RemoteMachine.markDisconnected`), not
from the last snapshot. An idle Mac sends none for hours. With the node not
running, every Mac shows offline, reasons included.

## Cache

`~/.zetty/remote-machines-v2.json`, mode **0600**, because it holds other
Macs' pane titles and directories. It is written at most once per 5s and on
quit, and loaded at launch with every machine offline. The pre-0.1.62
`remote-machines.json` (keyed by the Macs' old Tailscale devices) is deleted
when the client starts. A machine stays listed offline until its node leaves
the tailnet.

## Sidebar

With no machines the outline is exactly the local one: no **This Mac**
header. A machine group collapses while its Mac is offline. A user's
expand/collapse holds until the Mac next goes on- or offline. Remote rows
reuse `ProjectCellView`. Their colors come from
a stable hash of the project id into `ZTheme.projectPalette`, because
snapshots carry no colors. `TerminalViewController.setRemoteMachines` goes
through `setNeedsChromeRefresh`, since a feed can tick as fast as a title.

## Testing

- **`scripts/remote-e2e.sh --peer <user>@<lan-address>` runs the checklist
  below with nobody at either Mac** (`DEVELOPMENT.md` has the setup). This
  Mac serves and the peer views. Both run a copy of the build under
  `/tmp/zre`, each enrolled as its own **ephemeral** Tailscale device with
  `ZETTY_E2E_TAILSCALE_AUTH_KEY` (handed over in a 0600 file that teardown
  deletes), so the installed apps, their devices and their sessions are never
  touched. The script reads state through `zetty remote list --json` and
  drives the view with `remote open|close`. It types through a relay from a
  Python pty on the peer, then reads the result back with `capture`. It
  checks that neither copy listens on its Mac's own interfaces, that a relay
  with no Zetty to dial for it says so, and that **a client through the peer
  Mac's own Tailscale device is refused** ("isn't a Zetty"): the container /
  VM / second-account case. Leaving the view and opening it again must keep
  the same relay pids; they must end once this Mac's copy quits, and that copy
  must leave the peer's sidebar (it signs out as it quits). Wrong-protocol and
  impostor stand-ins are gone: a stand-in would now have to be a Zetty device
  on Glen's account. `RemoteText` and admission are unit-tested. Last run
  2026-11-10, Mac mini → laptop over a DERP relay: 22/22, 0 failed, with the
  first relay attempt connecting (before `FDPassing.handOver` it failed once
  over that slow link, so the size check failed).
- **The peer's copy is started as a bare binary over SSH, with nohup.**
  `open -n` can't start it: `LSMultipleInstancesProhibited` makes Launch
  Services hand the launch to the installed app (and drop `--env`). Started
  from SSH, the binary still reaches the window server while that user is
  logged in, so its panes get real surfaces.
- **A relay is `-<zetty> attach <ip>:<pane>`** (a login shell's `exec -l`),
  under `/usr/bin/login -flp … -c exec -l <zetty> attach …`, so a bare
  `pgrep -f "zetty attach"` counts two per pane. Count with
  `pgrep -f '^-?<zetty> attach'`.
- **Loopback, no Tailscale needed.** A scratch SwiftPM package that depends on
  this repo (`.package(path:)`) and links `ZettyCore`, with copies of
  `App/Sources/App/Remote/*.swift`, can run a real `RemoteServer` on
  `127.0.0.1` / `::1` with a fake `whois`, and a real `RemoteMachinesClient`
  against it. That is how phase 1 was checked: hello, snapshot, refusal,
  version mismatch, hello timeout, oversized frame, slow reader, drop and
  backoff, cache round trip. `listen` is async, so wait briefly before dialling.
- **The isolated test app is its own Zetty device** with its own sign-in
  (its Keychain item is keyed by its home, `/tmp/zti @ <hardware UUID>`), so it and the
  installed app can both serve, and each lists the other. Sign it in from its
  Settings, or launch it with `ZETTY_TAILSCALE_AUTH_KEY_FILE` for an
  ephemeral device. Remove its item afterwards with
  `security delete-generic-password -s co.webteractive.zetty.tailscale-state -a "/tmp/zti @ $(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}')"`.
- **Watch relays with `pgrep -fl "zetty attach"`.** Two lines per open
  remote pane (the relay and its login parent, above), gone within about a
  second of the pane closing on either Mac.
- **Two Macs, each Zetty signed in to Tailscale as Glen.** Serve on the mini,
  show on the laptop. `remote-e2e.sh` covers most of this. By hand: the
  mini's projects and dots appear and update within ~1s; sleeping the mini
  reads offline within about 50s (the feed heartbeat) and online again after;
  a build with another `RemoteProtocol.version` reads "needs update"; no copy
  lists itself.
- **A silent link, on one Mac** (checked 2026-11-24): two isolated copies,
  each its own ephemeral device (`ZETTY_TAILSCALE_AUTH_KEY_FILE`), both
  serving and showing. `kill -STOP` the serving copy: the other lists it
  offline about 50s after its last frame, logs `sent nothing for 45s`, and
  reconnects at its next retry after `kill -CONT`. Peers on an older build
  stay online throughout.
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

What that means for the relay: a pane opened on the laptop stays at the
mini's size until something claims it, and the screen that doesn't drive the
size shows output drawn for the other one. Programs position text for one
size, so the other Mac's window lays it on the wrong rows and columns: the
overlapping fragments Glen saw on 2026-11-06.

**What zmx forwards from a client that didn't type last** (zmx 0.8.1,
2026-11-06): only plain keys (letters, space, Backspace, Tab, Enter), and those
switch the size. Escapes (arrows), control keys, NUL, focus reports
(`CSI I`) and even non-ASCII (`é`) are dropped: the program never sees them
and the size stays. So an arrow key typed on the screen that doesn't drive is
lost, and neither focus nor a harmless control byte can claim the size
(neurosnap/zmx#299 asks for focus to claim it; don't post there without Glen).

### Taking the size back (`RemoteSizeHandoff`)

- **The claim is space then Backspace** (`RemoteSizeHandoff.claim`). It
  cancels out in a prompt or text field; Claude Code's permission menu kept
  its highlight on "1. Yes" (checked 2026-11-07). Pickers in a plain shell
  (less, fzf) still see the space.
- **The served pty starts raw** (`PTYProcess.spawn`). A relay sends the claim
  the moment it attaches, often before `zmx attach` has set raw mode. On a
  cooked pty the line discipline echoed it (`" \b \b"`) and Backspace erased
  the space, so zmx saw nothing, the size stayed the other Mac's, and the
  repaint replayed a screen drawn for it. It failed now and then, depending
  on timing, and a key typed afterwards always fixed it (found 2026-11-09).
  zmx doesn't flush input pending at startup, so raw from the start is
  enough. Output processing stays on for the `zmx history` replay.
- **Then a repaint**, once the program has redrawn: at least
  `RemoteSizeHandoff.settle` (0.4s), then until output that arrived after the
  claim has been quiet for `quiet` (0.15s), never past `settleLimit` (2.5s).
  The relay times it from the output it receives. Silence since the claim
  doesn't count as quiet: the serving Mac's attach may not have started yet,
  with the claim unread in its pty, and the repaint restarts that attach and
  throws the claim away. The laptop then believed it drove, a click did
  nothing, and only two arrow keys brought the size over (Glen, 2026-11-17,
  with the served script still waiting 4s on `zmx list`). A repaint at the
  limit that never heard back sends the claim again after itself, and that
  claim gets no repaint of its own: against a server without the attach
  marker, the replay of the repaint before it is still arriving when one
  would fire, and it would throw the claim away again (review of 70c34a5,
  2026-11-20). Scrollback above can then stay laid out for the other Mac;
  with matching builds the marker makes a second claim unnecessary.
  **The serving Mac marks its attach starting** (`RemoteSizeHandoff.attachMarker`,
  an APC string printed just before `exec zmx attach`, after any replay), and
  says so in its hello (`features: ["attach-marker"]`, additive, no protocol
  bump). Against such a server the relay strips the marker, waits for it
  (up to `attachLimit`, 10s) after an attach or a repaint, and times the
  repaint from it when it came after the claim, never counting the replay as
  the program's answer; a claim sent before it waited in the pty and was
  read, so no second claim follows. A replay of a few MB over a slow path,
  still arriving at the limit, was taken for the answer and its repaint threw
  away the unread claim (release review, 2026-11-20). A server without the
  feature gets the timing above. A fixed 0.4s let Claude Code on a long
  conversation still be redrawing, so the repaint replayed a half-drawn screen
  that stayed garbled until a key (Glen, 2026-11-16, laptop viewing the
  mini). The local pane's repaint still waits the fixed `settle`. Claiming alone redraws Claude Code's visible screen (it clears on
  a width change), but scrollback above stays mangled, so the screen in use
  restarts its attach from a clean replay of zmx's own copy, which is always
  right.
  - **Remote pane:** the relay sends a `repaint` frame; the server stops that
    connection's attach WITHOUT `detached` (which would hand the size back to
    the mini) and starts `plan.repaintArguments` at the relay's last size:
    history, then the clear and the replay together, then attach. Clearing
    before the history came back left the pane blank while zmx answered.
  - **Local pane:** SIGUSR1 to the attach under `scrollback-restore.sh`,
    which fetches the replay, clears and prints it at once, and reattaches
    (`session-preservation.md`). Never
    free and rebuild the surface for this: freeing a live preserved surface
    can freeze the app (`surfaces-and-memory.md`).
- **When.** The relay (`RelaySizeDriver`) claims on its first attach, then on
  focus or a key while it doesn't drive. The viewing Zetty tells it about
  focus with `RemoteSizeHandoff.focusMarker`, an APC string typed into the
  relay's pty on focus, window-key, click, and the pointer moving or
  scrolling over the pane (no key produces one; the relay strips it). The
  pointer is held to one marker per 0.5s; it counts because with the window
  already key and the pane focused, nothing else fires before the first key,
  and the user saw a mangled pane until they pressed an arrow (2026-11-09).
  **The pointer counts only in the Zetty in use** (app active, window key:
  `RemoteSizeHandoff.pointerClaims`). The terminal view tracks the pointer
  even in the background, so with Screen Sharing in front on the laptop one
  pointer crossed both the laptop's Zetty and the mini's (inside Screen
  Sharing), each claimed in turn with a full repaint, and the pane flipped
  between the Macs until the pointer rested (Glen, 2026-11-16). Clicks, keys
  and window-key still claim at once.
  No marker goes to a pane in its first 2s (`focusQuietPeriod`): until the
  relay sets raw mode the pty is cooked and echoes it as
  `^[_zetty-focus^[\`, which a refusal then leaves on screen. A new
  relay's first attach takes the size anyway.
  The serving Zetty (`RemoteSizeHandoffController`) claims for a
  local pane on the same events plus any key, but only for a session another
  Mac drives: the server tracks the driving relay per session (`drivers`),
  from its input and resize frames, and sends `sizeMoved` to relays when this
  Mac or another relay takes over. When the driving relay detaches, the mini
  repaints its own pane after the SIGWINCH below.
- **Known gaps.** `zetty send` into a pane another Mac drives claims the size
  through zmx without the server knowing, so that Mac's view goes stale until
  it takes the size back. A reconnect doesn't claim: the user may be at the
  other Mac.

**SIGWINCH puts it back** (checked 2026-11-04): after the last typist
detaches, `kill -WINCH` on another client's `zmx attach` pid makes zmx apply
that client's size (20×60 back to 40×100). So `RemoteTerminalHost.detached`
signals the session's own attach clients; no view jiggle is needed.

To repeat the check, point `ZMX_DIR` at a short path such as `/tmp/zsz`. A
long scratchpad path fails with "socket directory path is too long".
