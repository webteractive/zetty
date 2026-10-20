---
paths:
    - "scripts/release.sh"
    - "scripts/package.sh"
    - "Sources/ZettyCore/Update/**"
    - "App/Sources/App/UpdateChecker.swift"
    - "App/Sources/App/UpdateInstaller.swift"
commands:
    - "scripts/release.sh"
    - "scripts/package.sh"
triggers:
    - "cutting a release or writing its notes"
    - "changing packaging, signing, notarization or the self-updater"
---

# Releasing: scripts/release.sh, signing, the self-update swap

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

```sh
scripts/release.sh --notes notes.md patch      # or minor | major | X.Y.Z
```

The script is the whole process: preflight (clean tree, on `main`, up to date,
`gh` authed, tag free) → `swift test` → bump → commit → push → package → verify
→ tag → GitHub release with both assets. `--dry-run` prints the plan and
changes nothing; it refuses to run without a notes file. Afterwards it prints
the `ditto` line to refresh `/Applications` (Glen runs that copy, so it should
match the release — verify `ZettyBuildCommit` against HEAD).

**A generic release skill/tool WILL silently produce a broken release here.**
Zetty is a distributed macOS app, and the two failure modes are quiet:

- **The version lives in `Project.swift`** (`CFBundleShortVersionString`), not in
  a package manifest. A tool that looks for `composer.json`/`Cargo.toml` finds
  nothing to bump and ships a DMG stamped with the *previous* version — and
  since the update check gates on `SemVer.isNewer(latest:than:)`, the release is
  never offered.
- **The release must carry `Zetty-<version>.dmg` AND its `.sha256` sidecar**
  (`scripts/package.sh` writes both). `UpdateAssets.select` pairs them by name
  suffix and `UpdateChecker.isInstallable` requires *both*, with
  `UpdateChecksum.verify` checking the download — so a release missing either
  asset silently loses in-app updating and drops users back to a manual
  download. Artifact detection keyed to `Cargo.toml`/`go.mod`/`package.json`
  `bin` matches none of this and skips the upload *without warning* — the exact
  trap that motivated the script.

Other conventions the script encodes: the annotated tag lands on the
`chore(release): vX.Y.Z` commit (not on whatever HEAD happens to be), and the
tag/commit use `v`-prefixed SemVer. Notes are never generated from the commit
log — see Release notes below.

**The self-update swap must never delete the target before the replacement is
verified.** A field crash on 0.1.40 was a `/Applications/zetty.app` whose
`MacOS/zetty` was present but whose `ZettyGhostty.framework` was simply absent —
dyld rejects that before `main` runs, so nothing inside the app can detect or
repair it, and the user's only route back is a manual DMG reinstall. The shipped
DMG was verified complete, so the bundle lost the framework *after* install; the
one mechanism Zetty owns is the swap helper, which used to `rm -rf` the target
and then `ditto`, leaving whatever the copy managed to write if it was cut short
(a restart, a full disk). `SelfUpdateScript` now checks the staged bundle
against `requiredBundlePaths` before touching the target, moves the old bundle
to `<target>.zetty-previous` instead of deleting it, verifies the copy, and
restores the old bundle if anything failed — and every path still relaunches, so
a failed update leaves a working app rather than nothing.
`UpdateInstaller.mountAndCopy` runs the same completeness check on the bundle it
stages out of the DMG, while the app is still alive and the failure can surface
as an error instead of a silent rollback.

Signing: `scripts/package.sh` signs Release builds with the **Developer ID**
in the login keychain (hardened runtime, `--timestamp`, no entitlements),
notarizes and staples the app, THEN builds, signs, notarizes and staples the
DMG, and checks both with `spctl`. Order matters three ways: nested code
(`ZettyGhostty.framework`) is signed before the app whose seal covers it; the
app is stapled before the DMG is made, so the copy dragged out — and the copy
the self-updater lifts out — carries its own ticket; and the `.sha256` sidecar
is written last, because stapling rewrites the DMG. `notarytool` exits 0 on an
`Invalid` verdict, so the script reads the status from its JSON and prints
Apple's log on rejection. No secret lives in the repo: notarytool uses the
`notary` keychain profile (`ZETTY_NOTARY_PROFILE` / `ZETTY_SIGN_IDENTITY`
override). `release.sh` runs `package.sh --preflight` before its bump, so a
missing certificate or profile stops it before it pushes; `--adhoc` packages
an un-notarized build for a machine without the certificate — never ship it.
Releases up to 0.1.52 were ad-hoc signed.

## Release notes

**Every release ships human-written notes.** When cutting a release, add a
note to the GitHub release body summarizing the updates and new features it
introduces — a short, user-facing "What's new" list, not just the
auto-generated "Full Changelog" link. Group by feature/fix and phrase it for
users, mirroring the same changes documented in `README.md`.
