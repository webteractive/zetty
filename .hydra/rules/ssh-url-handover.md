---
paths:
    - "Sources/ZettyCore/CLI/SSHURLHandler.swift"
triggers:
    - "handling ssh:// URLs or other URL schemes"
    - "an external open lands in the wrong app copy (Launch Services)"
---

# ssh:// URL handover

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

Zetty is a registered macOS `ssh://` handler (`CFBundleURLTypes` in
`Project.swift`). A handover URL from another app arrives at
`AppDelegate.application(_:open:)`, which validates it via the pure
`SSHURLHandler` (`ZettyCore` — strict charset; untrusted external input, so the
`ssh` command is built from validated tokens only, never a shell-interpolated
raw string) and opens a focused new **Home** tab running the command through
`TerminalViewController.openSSHSession(command:)` (existing
`pendingStartupCommands` → `sendText` path). URLs that arrive before the
workspace is ready on cold launch are queued and drained at the end of
`applicationDidFinishLaunching`. Clicking `ssh://` links *inside* Zetty's own
terminals is NOT handled (that needs the unwired
`TerminalSurfaceOpenURLDelegate`).

**Stale-copy gotcha:** every `xcodebuild` auto-registers its product with
Launch Services (`lsregister -f -R -trusted`), so dev builds in
`build/`/DerivedData compete with `/Applications/zetty.app` for scheme and
bundle-id resolution. The post-build stamp script writes a monotonic
`CFBundleVersion` (git commit count) so LS ranks the newest build highest —
old strays lose instead of tying at the default `1.0`. Keep `/Applications`
current (the usual rebuild-and-install step) and delete/`lsregister -u` stray
`.app` products if an external open lands in the wrong copy.
