# Update Notification — Design

**Date:** 2026-07-06 · **Status:** Approved

Notify the user when a newer Zetty release is available for download. Notify-only
(no auto-update/Sparkle) — a status-bar pill and an App-menu item that link to
the release's download page.

## Decisions (settled with Glen)

| Question | Decision |
|---|---|
| Version source | GitHub Releases API (repo made **public**): `https://api.github.com/repos/webteractive/zetty/releases/latest` |
| Notify style | **Status-bar pill** (click → open release page) + App menu **"Check for Updates…"** |
| Cadence | On launch (throttled ~once/6h) **+** periodic timer (~6h) |
| Opt-out | Reserved config key **`check-updates`** (default `true`) |
| Action | Notify + open the release page in the browser. No auto-download/install. |

## Architecture

- **Pure core (`ZettyCore`, tested)** — `SemVer` + `SemVer.isNewer(latest:than:)`:
  parses `MAJOR.MINOR.PATCH` (strips a leading `v`), compares numerically, and
  returns **false** when either side is unparseable. So a `dev`/missing current
  version (the "vdev" bundles) never triggers a nag.
- **App layer** — `UpdateChecker` (URLSession): fetches the API, decodes
  `tag_name` + `html_url`, compares against `CFBundleShortVersionString`, and
  publishes an optional `AvailableUpdate(version: String, url: URL)`. Network +
  JSON decode live here; the version comparison is core.

## Data flow

```
launch (throttled) / timer / manual menu
  → UpdateChecker.check()
    → GET api.github.com/repos/webteractive/zetty/releases/latest
    → decode tag_name ("v0.1.7"), html_url
    → SemVer.isNewer(latest: tag, than: CFBundleShortVersionString)?
        yes → publish AvailableUpdate(version, url)
              → status bar shows the pill
        no  → clear any pill
  → manual check also surfaces "You're up to date." when not newer
```

## UI

- **Status-bar pill** — appears only when an update is available: "Update
  available (0.1.7)", accent-tinted per `ZTheme`; click → `NSWorkspace.shared
  .open(url)`. Hidden otherwise. Lives in `StatusBarView` alongside the version
  stamp.
- **App menu → "Check for Updates…"** — manual trigger. Newer → shows/updates
  the pill and can open the page; not newer → a small "You're up to date."
  alert; failure → "Couldn't check for updates." alert.

## Cadence + throttle

- On launch: check once if ≥6h since the last check (last-check timestamp in
  `UserDefaults`, key `Zetty.lastUpdateCheck`).
- Periodic: a repeating timer (~6h) while the app runs.
- All auto-checks are gated by `check-updates`; the manual menu item always runs
  regardless (an explicit user action), and does not require the timestamp gate.

## Config

New reserved key in `AppConfig`:

- **`check-updates = true | false`** (default `true`) — when false, no automatic
  (launch/periodic) checks happen; the manual menu item still works. Parsed +
  unit-tested in `ZettyCore` like the other reserved keys.

## Error handling

- **Auto-check failure** (offline, rate-limited, decode error) → silent; leave
  any existing pill as-is, try again next cycle.
- **Manual-check failure** → "Couldn't check for updates." alert.
- **Current version is `dev`/unparseable** → skip (never nag) — `SemVer.isNewer`
  returns false; also short-circuit before the network call.
- **No secrets** — unauthenticated public endpoint; no token in the app.

## Testing

- **`ZettyCore` (swift-testing):**
  - `SemVer` parse/compare: `0.1.6 < 0.1.7`, equal not newer, `0.2.0 > 0.1.9`,
    leading `v` handled, malformed / `dev` / empty → not newer.
  - `AppConfig` parses `check-updates` (true/false, default true), like existing
    reserved-key tests.
- **App layer** (not unit-tested — URLSession/AppKit): verified live once
  v0.1.7 exists — an older local build shows the pill; clicking opens the
  release page; `check-updates = false` suppresses auto-checks; the menu item
  reports up-to-date / available / error.

## Prerequisite (separate step)

Making the repo public exposes the **entire commit history** permanently. Before
flipping: scan history for committed secrets (`.env`, keys, tokens); only flip
if clean. This is done as its own action, not part of the feature code.

## Non-goals (v1)

- Auto-download / auto-install (no Sparkle). Notify + link only.
- Release notes / changelog display in-app (the release page has them).
- Pre-release / beta channel selection.
