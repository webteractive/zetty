---
paths:
    - ".package.resolved"
commands:
    - "scripts/check-libghostty.sh"
triggers:
    - "check-libghostty reports a newer libghostty than the pin"
    - "bumping the libghostty-spm pin in Project.swift"
---

# Checking and bumping libghostty

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

**Before starting any feature, bug fix or other change to the app, run
`scripts/check-libghostty.sh`** — once per working session is enough. It
compares the `libghostty-spm` pin in `Project.swift` with upstream's release
tags and changes nothing. Zetty IS libghostty with chrome around it, so a
terminal fix that already exists upstream is the cheapest fix available, and
the pin only moves when somebody looks.

- **When the script reports anything newer, delegate the research to a
  subagent before touching the pin** — one read-only agent, briefed with the
  pinned version and revision, the newer tag(s), and where Zetty's bridge code
  lives (`App/Sources/ZettyGhostty/`). It must come back with, each backed by
  a tag, commit or quoted release note: what changed between the two versions,
  split into the Swift wrapper's API and the bundled upstream ghostty build;
  any symbol Zetty uses that was removed, renamed or changed; anything
  touching what Zetty is sensitive to (per-surface memory, `ghostty_surface_free`,
  config validation, key handling, rendering, shell-integration resources);
  and whether an existing tag was moved. It is delegated because the answer
  is a read across release notes, commit ranges and upstream ghostty, and
  only the conclusion belongs in the session doing the actual work.
- **Show Glen what the new version contains BEFORE bumping**, in the reply,
  not only in a commit message: the changes, what was verified against what
  was inferred, and where upstream recorded nothing. "A newer version exists"
  is not a reason to bump, and an empty release note is a finding to state
  rather than to skip past.
- **A newer release on the pinned line** (same `major.minor`, e.g. `1.6.x`):
  once that has been shown, bump `from:` in `Project.swift` to it, as its OWN
  commit ahead of the work the session was started for. `tuist generate` then
  rewrites the tracked `.package.resolved`, which belongs in the same commit:
  it is the lockfile, and a transitive dependency can change with the bump
  (`1.6.20261003` swapped `MSDisplayLink` for `DisplayLink`).
- **Clean before building a bump** (`xcodebuild … clean`). The precompiled
  libghostty module from the old pin is rejected with "ghostty.h has been
  modified since the module file was built", which reads like a broken
  release and is only a stale cache.
- **Clean the RELEASE build folder too**, which is a separate cache:
  `xcodebuild -project zetty.xcodeproj -scheme zetty -configuration Release
  -destination 'generic/platform=macOS' -derivedDataPath build clean`. Skip it
  and `scripts/release.sh` fails at packaging with that same error — AFTER it
  has committed and pushed the `chore(release)` commit, which leaves a pushed
  version bump with no tag and no release. That happened on v0.1.49. The way
  out is to clean `build/`, run `scripts/package.sh`, repeat the script's own
  checks (checksum against the sidecar, packaged version, commit stamp), then
  tag the release commit and `gh release create` with both assets. Do NOT
  re-run `release.sh`: it would bump the version a second time.
- **A newer LINE** (e.g. `2.2.x` while pinned to `1.6.x`): not a routine bump.
  The same research covers it; say what the line is and let Glen decide; a new line can remove API, and the last move
  across lines (`32ae982`) lost `TerminalSurface.sendText`.
- **State the result either way** — "libghostty is current" or what is newer —
  in the summary of the work. A check nobody reports is a check nobody can
  tell was run.
- **A bump is a change like any other**: it ends with the install ritual
  (`install-after-change.md`), and it is not verified until the installed
  app has been exercised — typing, splits, copy mode, and a preserved
  session reattaching. `swift test` never links libghostty, so a bump that
  compiles and passes is still unproven.
- **Read the resolved revision after bumping** (`.package.resolved`) and
  compare it with `git ls-remote --tags` for that tag. Upstream has
  rewritten history under existing tags before, leaving a pin pointing at a
  revision a fresh clone no longer contains.
- The script exits 2 when it cannot reach GitHub. Offline is not "up to date":
  say the check could not be run.
