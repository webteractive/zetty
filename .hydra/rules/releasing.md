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
scripts/release.sh --notes notes.md --review review.md patch   # or minor | major | X.Y.Z
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
(`ZettyGhostty.framework`, and the bundled `Contents/Helpers/zmx` with
identifier `co.webteractive.zetty.zmx`) is signed before the app whose seal
covers it; the
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

## Pre-release review (required, 2026-11-13)

Glen: "Fix all bugs or look for bugs and fix and ensure every release is free
from it." Every release is preceded by a bug sweep and a security review of
everything since the last tag, and `scripts/release.sh` refuses to run
without the record (`--review <file>`).

1. **Range:** `git log --oneline $(git describe --tags --abbrev=0)..HEAD`.
2. **Bug sweep:** fresh, read-only reviewers on the most capable model, one
   per area the range touches (split by feature, not by file), each briefed
   with the area's rule file and the failure modes the tests don't exercise:
   hangs and main-thread blocking, races, crashes, data loss on upgrade,
   untrusted input reaching a pane or a command line, and what an existing
   user's state looks like after updating. They report concrete findings
   with a failure scenario; a finding is fixed with a test that failed first
   wherever one can be written.
3. **Security review:** the `security-review` skill on the same range
   (global rule `release-security-review.md`). Only Glen accepts a finding
   unfixed.
4. **Regression checks** that tests can't cover, in the isolated test app:
   turning the Claude mod off and reloading, then opening a tab (the
   environment crash, `surfaces-and-memory.md`); a session started by the
   previous zmx pin still attaching, reading back and ending
   (`session-preservation.md`); a hibernate and a `quit --kill-sessions`
   returning promptly.
5. **The record**, a file outside the repo like the notes, with:
   - `Reviewed: <last tag>..<HEAD short sha>`: exactly the range released, so
     a commit after the review sends it back;
   - each finding and what happened to it;
   - `Unresolved: none`, or `Unresolved: accepted by Glen …`.

`swift test` (which release.sh runs) also carries source guards
(`ReleaseGuardTests`) for bug classes that shipped once: process-environment
changes after the first pane, and listing zmx with `--short`. Add a guard
there when a bug class can be caught by reading the source.

## Release notes

**Every release ships human-written notes.** When cutting a release, add a
note to the GitHub release body summarizing the updates and new features it
introduces — a short, user-facing "What's new" list, not just the
auto-generated "Full Changelog" link. Group by feature/fix and phrase it for
users, mirroring the same changes documented in `README.md`.
