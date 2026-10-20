---
commands:
    - "ditto "
    - "open -a /Applications/zetty.app"
    - "zetty quit"
triggers:
    - "finishing a committed feature, fix or dependency bump"
    - "installing a build into /Applications/zetty.app"
---

# Installing after a change

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

**Every feature, fix or dependency bump ends with the running app on the new
build.** Verifying BEFORE the commit is not this: that runs in a temporary
isolated copy beside Glen's app (`.hydra/rules/isolated-test-app.md`), never
by quitting or replacing `/Applications/zetty.app`. Glen runs `/Applications/zetty.app`, so work that only reached
DerivedData is work he cannot see — a feature reported as "not there" when it
was built but never installed is what put this rule here. Do it automatically
after the commit; do not ask first.

```sh
zetty quit; sleep 2
xcodebuild -project zetty.xcodeproj -scheme zetty \
  -destination 'platform=macOS' build
ditto <DerivedData>/Build/Products/Debug/zetty.app /Applications/zetty.app
defaults read /Applications/zetty.app/Contents/Info.plist ZettyBuildCommit
open -a /Applications/zetty.app
```

- **Build AFTER committing.** The stamp script writes the short commit with a
  `*` suffix on a dirty tree, so a build run before the commit installs a
  bundle whose `ZettyBuildCommit` does not match HEAD. Verify the two are
  equal rather than assuming; they are the only evidence the copy is current.
- **Regenerate first if `tuist test` ran** — it rewrites the xcodeproj without
  the script phases, so the stamp silently does not run at all.
- **Restarting is part of it.** The live process keeps executing the OLD
  in-memory code until it is relaunched, so an install without a restart looks
  exactly like an install that did not happen. `preserve-sessions` reattaches
  the workspace, so the restart is cheap.
- **`ditto` in place, never `rm -rf` first.** Overwriting the bundle while the
  app runs is safe; deleting it is not — `ZettyGhostty.framework` is
  lazy-loaded, so once the bundle vanishes the live process dies with a
  `DYLD library missing` SIGABRT and pops a crash report. That crash is a
  self-inflicted install race, NOT a defect in the new build, and it has been
  misread as one.
- **Before `zetty quit`, confirm this session's own surface is in
  `zetty status`** (`${ZMX_SESSION#zetty-}`). The startup reap kills every
  `zetty-*` session no restored surface owns, so an untracked one is killed on
  relaunch — taking the agent doing the install with it. Run quit → wait →
  open as one backgrounded command so it survives the GUI being briefly down.
- **`ditto` never removes what the new build dropped.** It merges into the
  existing bundle, so a file deleted or renamed in the repo stays in
  `/Applications/zetty.app` from an older install. Renaming the mod's
  `register.ts` to `register.tsx` left both in the installed bundle, and
  `ModInstaller` then copied the dead one out. After an install whose change
  removed or renamed a bundled resource, delete the leftover by hand and run
  `codesign --verify --deep /Applications/zetty.app` — an extra file breaks the
  bundle's seal until it is gone. A released DMG is a fresh bundle and is not
  affected.
- **For a release, install the Release build** (`build/Build/Products/Release/`
  from `package.sh`), so `/Applications` matches the shipped DMG.
- **A dependency bump counts as a change.** `swift test` covers only the pure
  `ZettyCore` target and never links libghostty, so a bump that compiles is
  still unverified — the installed app being exercised is the verification.
