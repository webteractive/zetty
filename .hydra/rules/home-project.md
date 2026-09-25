---
triggers:
    - "changing the Home project or zetty-home-path"
    - "removing, hibernating, or restoring projects"
---

# Home project

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

A permanent **Home** project (`ProjectRuntime.isHome`) is seeded by default
(`WorkspaceModel.init(homeRoot:)` / `makeHome(rootPath:)`, rooted at `~` unless
`zetty-home-path` moves it). It renders as a single
row pinned to the very top of the sidebar — **no section header**, **no pin
button**, a default **`house.fill`** glyph (overridable by a custom icon), and
**no expandable tab children** (tabs still work, they're just not listed in the
sidebar). It stays put and dims when hibernated (never moves to Hibernating).
It can be
hibernated/woken like any project but **never removed**: `removeProject(at:)`
rejects `isHome`, the sidebar row omits its Remove item, and CLI
`remove-project Home` returns an error. Because Home is the guaranteed floor,
the old "can't remove the last project" rule is gone — every other project
(incl. the last non-home one) is freely removable, and `hibernateProject` may
now hibernate the last awake project (the dormant placeholder renders).
Restore injects a Home when a saved workspace has none
(`WorkspaceModel.restored(from:activeIndex:homeRoot:)`), so existing users' old
home-rooted project stays as an ordinary, now-removable project. Home's
settings are keyed by the reserved sentinel `ProjectSettingsStore.homeKey`
(`@home`) via `ProjectRuntime.settingsKey`, so they never collide with a
user-added `~` project — including one at the same path as a custom
`zetty-home-path`. `isHome` is persisted in `workspace.json`.

**`zetty-home-path` re-roots Home, and the CONFIG wins over
`workspace.json`.** `AppConfig.homePath` (raw, `~` unexpanded) resolves through
the pure `resolvedHomePath(defaultHome:)`; the App layer's
`AppDelegate.resolvedHomeRoot` is what checks the directory exists, falling back
to `NSHomeDirectory()` with a `ZettyLog.config` line rather than an alert (Home
is the sidebar's guaranteed floor and must always open somewhere, and ⇧⌘, re-reads
the config — an alert per reload while a volume is unmounted is worse than a
quiet fallback). `restored(from:activeIndex:homeRoot:)` re-roots the persisted
Home on every launch and `setHomeRoot` handles reload; both are why dropping the
key moves Home *back* to `~` instead of stranding it. Re-rooting must set
`TabList.setDefaultWorkingDir` as well as `rootPath` — that's the load-bearing
half, since new tabs spawn from the tab list's default dir, and the feature is
NEW panes only (a live shell owns its cwd; a preserved zmx session captured it at
creation). Scratch terminals stay rooted at the real home.

The GUI for it is a **Working Directory** row in Project Settings' General tab,
present **only for Home** (`homeDirectory != nil` builds the row; every other
project is rooted where it was added, so it's absent rather than disabled). It
does NOT go through `ProjectSettings`: the sheet takes a second output channel
(`onSaveHomeDirectory`) straight to `AppDelegate.setHomeDirectory`, which writes
the global key via the pure `AppConfig.homePathValue(for:defaultHome:)` — the
inverse of `resolvedHomePath`, tilde-abbreviating so the file stays portable and
returning nil when the pick IS the home directory (so "Use Default" clears the
key instead of pinning `~`). Storing it in `project-settings.json` instead would
create a second source of truth and a precedence rule for the same value.
