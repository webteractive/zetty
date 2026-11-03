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
the sidebar under **This Mac**. It is view-only. Remote rows can't be selected,
dragged, dropped on, pinned or opened.

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
  ("offline · seen 2h ago", "needs update", a refusal reason) or the status
  line in Settings → General → Other Macs.

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
  length, then JSON (`RemoteMessage`: `hello`, `snapshot`, `refused`).
- A frame over **8 MiB** closes the connection before its body is read.
- Each side sends `hello` first. The server waits 5s for the client's, then
  closes. Another `protocolVersion` keeps the connection open with no
  snapshots, and the client shows "needs update". Bump
  `RemoteProtocol.version` only for an incompatible message change.
- The server drops a peer with more than 8 frames queued (a slow or dead
  reader), and accepts at most 32 connections, since each one costs a
  `whois` process.
- Snapshots are `StatusSnapshot` (the `zetty status` model), published from
  the end of `refreshSidebar()` only when they differ from the last one sent.
  That is the coalesced path, so a busy agent can't flood the wire.
- The client dials a node's first IPv4 with a 3s connect timeout and TCP
  keepalive (10s idle, 3s × 2 probes), so a Mac that sleeps without a FIN
  goes offline in about 16s. It retries a drop after 5, 10, 30, then 60s, and
  the backoff resets on the next snapshot.
- `TailscaleMonitor` polls every 10s, and only while one of the two keys is on.

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
- **Two Macs, both signed in to Tailscale as Glen.** Serve on the mini, show on
  the laptop. Check: the mini's projects and dots appear and update within
  ~1s; `tailscale down` or sleeping the mini gives offline within ~16s and
  online again after; `printf '\xff\xff\xff\xff' | nc <ip> 47391` from the
  mini closes only that connection; a build with another `RemoteProtocol.version`
  reads "needs update"; neither copy on one Mac lists itself.
- Screenshots are TCC-denied in agent sessions, so the sidebar's look needs a
  human.

## Open for phase 2

zmx with two clients at different sizes: confirm what zmx 0.6 does before
relying on "last typist wins". If it can't follow input, pick the least
surprising rule and record it here.
