# In-app self-update (Option B) — design

**Date:** 2026-07-07
**Status:** Approved design, pending implementation plan
**Feature:** Trigger-based self-update — the app downloads, verifies, and installs
a newer release in place, then relaunches, instead of only opening the release
page in a browser.

## Summary

Zetty already checks GitHub `releases/latest` (`UpdateChecker`) and, when a newer
version exists, shows an accent "↑ Update X" pill and a "Check for Updates…" menu
item. Today both just **open the release page** — the user downloads the DMG,
drags it to `/Applications`, and strips the Gatekeeper quarantine by hand.

This feature turns that last manual chore into an in-app flow: on the same
trigger, show a confirm dialog, then **download the DMG, verify its SHA-256,
swap the running app bundle in place, and relaunch**. No new frameworks
(Sparkle rejected — it wants Developer ID + notarization + a signed appcast,
which the ad-hoc-signed distribution model doesn't have).

Decisions locked with the user:
- **Verification: SHA-256 checksum** published alongside the DMG.
- **Trigger UX: confirm dialog, then install** (Install & Restart / View Release
  Notes / Later).

## Non-goals (YAGNI)

- Auto-check on launch or background/silent updates — trigger-only.
- Delta updates, rollback, staged rollout.
- Developer ID signing / notarization / EdDSA (noted as a future upgrade path,
  not built now).

## Current architecture (what we build on)

- `App/Sources/App/UpdateChecker.swift` — hits `releases/latest`, decodes
  `tag_name` + `html_url`, compares via `ZettyCore.SemVer`, returns
  `AvailableUpdate { version, url }` (url = release page). Notify-only.
- `AppDelegate.versionPillClicked()` / `checkForUpdates(_:)` — run the check;
  on a hit, call `terminalViewController?.showUpdate(update)` and open the page.
- `StatusBarView` version pill — build version button that flips to the accent
  "↑ Update X" state when `pendingUpdate` is set.
- `scripts/package.sh` — Release build → `dist/Zetty-<version>.dmg`
  (ad-hoc signed, so downloads are Gatekeeper-quarantined; README documents the
  `xattr -d com.apple.quarantine` step).
- Release ritual (per project convention): version bump + `package.sh` + tag +
  `gh release` uploading the DMG.
- **Session preservation synergy:** with `preserve-sessions` on, panes run in
  zmx sessions that survive quit/relaunch — so a self-update relaunch reattaches
  panes automatically. With it off, it's a normal cold start.

## Design

### 1. Release artifacts — publish a checksum

`scripts/package.sh` gains one step after building the DMG:

```sh
shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"
```

producing `dist/Zetty-<version>.dmg.sha256` (bare lowercase hex digest, no
filename). The release ritual uploads **both** `Zetty-<version>.dmg` and
`Zetty-<version>.dmg.sha256` as release assets. The `.dmg.sha256` naming
convention is the contract the updater relies on.

### 2. Richer update metadata (pure, in ZettyCore where possible)

Extend the release decode to include assets:

```swift
struct ReleaseAsset: Decodable { let name: String; let browserDownloadURL: URL }
// Release gains: let assets: [ReleaseAsset]
```

`AvailableUpdate` grows to:

```swift
struct AvailableUpdate {
    let version: String
    let releasePage: URL       // was `url` — "View Release Notes"
    let dmgURL: URL?           // asset ending in ".dmg"
    let checksumURL: URL?      // asset ending in ".dmg.sha256"
}
```

Asset selection is **pure and unit-tested** — a new `ZettyCore` helper
`UpdateAssets.select(from assets:) -> (dmg: URL?, checksum: URL?)` that matches
by name suffix (`.dmg`, `.dmg.sha256`). `UpdateChecker` (App layer, does I/O)
calls it after decoding.

**Installable vs. notify-only:** an update is *installable* only when both
`dmgURL` and `checksumURL` are present. Older releases (or a botched upload)
lack them → we fall back to the current behavior (open the release page) and the
confirm dialog omits "Install & Restart".

### 3. Installer orchestration (App layer)

New `App/Sources/App/UpdateInstaller.swift` — an `@MainActor` object driving a
small state machine, reporting progress to a delegate/closure:

```
idle → downloading(fraction) → verifying → staging → relaunching → (terminate)
                     └────────────── failed(reason) ──────────────┘
```

Steps:

1. **Download** the DMG to a work dir under
   `~/Library/Caches/<bundleID>/self-update/` via a `URLSession` download task;
   report `fraction` from the progress callback. (URLSession downloads are not
   quarantine-flagged the way browser downloads are; the helper strips
   quarantine regardless.)
2. **Verify** — download the `.sha256`, compute the local file's SHA-256
   (`CryptoKit.SHA256`), compare case-insensitively to the published hex. Any
   mismatch → `failed`, delete the download, nothing on disk is touched.
3. **Stage** — `hdiutil attach -nobrowse -readonly <dmg>`, parse the mount
   point, `ditto "<mount>/zetty.app" "<workdir>/zetty.app"`, `hdiutil detach`.
   (`ditto` preserves the ad-hoc signature.)
4. **Resolve target** = `Bundle.main.bundlePath` — update wherever the app
   actually runs, not a hardcoded `/Applications`. Pre-check the target's parent
   directory is writable; if not, `failed` with a clear message *before*
   quitting (never leave the user with a half-swapped app).
5. **Relaunch** — write a generated helper to `~/.zetty/self-update.sh`
   (same pattern as `~/.zetty/scrollback-restore.sh`), launch it detached
   (`Process`, its own session), then `NSApp.terminate(nil)`.

The helper script (contents generated by a **pure**
`SelfUpdateScript.render(pid:targetAppPath:stagedAppPath:dmgPath:)` in
ZettyCore, unit-tested):

```sh
#!/bin/sh
# wait for the running app (PID) to exit
while kill -0 <PID> 2>/dev/null; do sleep 0.2; done
ditto "<staged>/zetty.app" "<target>"            # swap in place
xattr -dr com.apple.quarantine "<target>" 2>/dev/null || true
rm -rf "<workdir>"                               # clean staged app + dmg
open "<target>"                                  # relaunch
rm -- "$0"                                       # remove this helper
```

Because the swap + quarantine strip happen in our own helper (not via a
Gatekeeper first-launch), there is no Gatekeeper prompt on relaunch.

### 4. Trigger UX

`versionPillClicked()` / `checkForUpdates(_:)` change: after a successful check
returning an *installable* update, present an `NSAlert` (sheet on the main
window):

> **Update to 0.1.11?**
> Zetty will download the update and restart.
> [ Install & Restart ]  [ View Release Notes ]  [ Later ]

- **Install & Restart** → run `UpdateInstaller`, showing a **modeless progress
  sheet**: determinate download %, then "Verifying…", "Preparing…",
  "Restarting…". Guard against a second trigger while an install is in flight.
- **View Release Notes** → open `releasePage` (today's behavior).
- **Later** → dismiss; pill stays in its "↑ Update X" state.

Non-installable update (no DMG/checksum asset) → the current dialog with only
"View Release Notes" / "Later". Up-to-date and error paths keep today's
`showUpdateInfo(...)` messages. Any installer `failed` → an `NSAlert` with the
reason; the current app is untouched and fully usable.

## Error handling (summary)

| Failure | Behavior |
|---|---|
| Offline / API error | Existing "Couldn't check for updates." |
| Release has no `.dmg`/`.sha256` asset | Dialog offers only release page |
| Download fails | `failed`, alert, cache cleaned, app intact |
| Checksum mismatch/missing | `failed`, alert, download deleted, app intact |
| `hdiutil` attach/detach fails | `failed`, alert, cleanup, app intact |
| Target parent not writable | `failed` *before* quitting, app intact |
| Second trigger mid-install | Ignored (in-flight guard) |

Nothing on disk is replaced until the detached helper runs after terminate, so
every pre-relaunch failure leaves the installed app exactly as it was.

## Security note

The app is ad-hoc signed and un-notarized. SHA-256 verification guarantees the
downloaded DMG matches the digest published in the release — it protects against
corrupt or swapped *assets*, given trust in the GitHub release + repo over HTTPS.
It is **not** cryptographic authentication of the publisher. The upgrade path,
when an Apple Developer account exists, is Developer ID signing + notarization
(and optionally an EdDSA-signed feed); this design deliberately leaves room for
that without depending on it now.

## Purity / testing

Pure, unit-tested in `ZettyCore` (`Tests/ZettyCoreTests/`):
- `SemVer.isNewer` — already covered.
- `UpdateAssets.select(from:)` — picks `.dmg` and `.dmg.sha256` from an asset
  list; handles missing/duplicate/extra assets.
- SHA-256 hex comparison helper — case/whitespace normalization.
- `SelfUpdateScript.render(...)` — exact script text for given inputs (PID,
  paths with spaces quoted correctly).

App-layer orchestration (`UpdateInstaller`, dialogs, progress sheet) is thin and
verified manually: real update from version N-1 → N with `preserve-sessions`
on (panes reattach) and off (cold start), plus a forced checksum mismatch to
confirm the abort path leaves the app intact.

## Files

- `scripts/package.sh` — emit `.dmg.sha256`.
- `App/Sources/App/UpdateChecker.swift` — decode assets, richer `AvailableUpdate`.
- `Sources/ZettyCore/…/UpdateAssets.swift` (+ SHA/script helpers) — pure logic.
- `App/Sources/App/UpdateInstaller.swift` — new orchestration + state machine.
- `App/Sources/App/AppDelegate.swift` — confirm dialog, install wiring, progress.
- `Tests/ZettyCoreTests/…` — asset selection, checksum compare, script render.
- README — note the manual `xattr` step is now automatic for in-app updates.
- Regenerate Tuist project after adding source files.
