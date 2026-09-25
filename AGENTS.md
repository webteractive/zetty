# Zetty — Agent & Contributor Guide

Guidance for AI agents and contributors working in this repo.

> **`CLAUDE.md` and `AGENTS.md` are kept byte-identical** — edit one and mirror
> the change to the other in the same commit (see Conventions).

## What this is

Zetty is a native macOS (Linux later) GUI **terminal multiplexer** built on
**full libghostty** (via the prebuilt `libghostty-spm` package) with a Swift
AppKit application layer. Work is organized around pinnable **projects**, each
owning **tabs** and nested **split panes**. See [`README.md`](README.md).

## Layout

- `Sources/ZettyCore/**` — pure, testable model (no AppKit): `Surface`,
  `SurfaceNode`, `PaneTree`, `TabList`, `WorkspaceModel`, persistence.
- `App/Sources/App/**` — AppKit app: `AppDelegate`, `TerminalViewController`,
  `SidebarView`, `TabBarView`, `SurfaceNodeView`, `PaneActions`, `Theme.swift`.
- `App/Sources/ZettyGhostty/**` — libghostty bridge: `SurfaceRegistry`, `Ghostty`.

## Build / run

The Xcode project is **Tuist-generated**. `Project.swift` declares sources as
**globs** (`App/Sources/App/**`), but the generated `.xcodeproj` enumerates the
resolved file list — so **after adding or removing a file you must regenerate**.
You do *not* edit `Project.swift` to register a new file; only new targets,
resources, or settings need a manifest change. Files under `Sources/ZettyCore/`
need nothing at all for `swift test` (SwiftPM globs them at build time).

```sh
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'generic/platform=macOS' build
```

Tests: `mise exec -- tuist test` runs the app test target. The pure `ZettyCore`
suite is faster via SwiftPM — `mise exec -- swift test` — and a single test with
`--filter`, e.g. `mise exec -- swift test --filter moveProjectRejectsCrossGroupMove`.

## Design rules  ← read before any UI work

The *visual* spec (tokens, schemes, typography, component anatomy) is in
**[`DESIGN.md`](DESIGN.md)**; tokens live in
[`App/Sources/App/Theme.swift`](App/Sources/App/Theme.swift) (`ZTheme`). DESIGN.md
is appearance-only — these enforceable rules (and Configuration, below) live here.
A change that violates one should be corrected before merge:

1. **Never hardcode a color.** Read from `ZTheme.current.<token>Color`; add a
   token rather than inlining hex or a system color (`.controlAccentColor`,
   `.separatorColor`, `.windowBackgroundColor`, …).
2. **Fonts:** only the terminal and the status bar use `ZTheme.monoFont`, which
   follows the user's configured terminal `font-family`/`font-size`. Every other
   piece of chrome — tab bar, sidebar, command palette, dialogs, sheets, chips —
   uses `ZTheme.chromeFont` (system font, fixed point size), so changing the
   terminal font never reflows the app chrome. This is deliberate and the
   opposite of what "terminal-native" suggests; don't "fix" a system-font tab
   label back to mono.
3. **Accent = focus/active/brand only, and it glows.** Selection/active fills use
   `bg3`, never a saturated accent block.
4. **Respect the surface ramp:** `bg0` chrome (sidebar / tab bar / status bar) ·
   `bg1` base/panes/terminal · `bg2` elevated inputs & hover · `bg3`
   chips/selection. Don't invent intermediate greys.
5. **Panes are borderless;** focus is shown by the accent status dot, not a border.
6. **The terminal tracks the scheme** via `ZTheme.current.terminalTheme()`,
   applied through `SurfaceRegistry.terminalTheme` — set it nowhere else. (Pasted
   ghostty directives may override terminal colors; see Configuration.)
7. **Schemes are all-or-nothing:** a new `ZColorScheme` fills every token plus
   its `isDark` flag.
8. **Semantic colors carry meaning** (green=ok, yellow=attention, red=error,
   purple=git, `fg3`=idle). Don't repurpose them for decoration.
9. **Chrome depth is borders + surfaces, not shadows;** reserve glow for the
   accent on focused/active elements.

When adding UI, match the component anatomy in DESIGN.md (radii, bar heights,
status dots, accent top-bar on the active tab, etc.).

## Configuration

Zetty reads `~/.config/zetty/config` (or `$XDG_CONFIG_HOME/zetty/config`),
seeded with a documented default on first launch. Parsing is pure + unit-tested
in `ZettyCore` (`AppConfig` / `ConfigStore`); `AppDelegate` resolves + applies it.

- **`appearance = system | dark | light`** — `system` (default) follows macOS
  live (KVO on `NSApp.effectiveAppearance`); `dark`/`light` pin one axis.
- **`theme-dark` / `theme-light`** — the `ZColorScheme` for each axis (case-insensitive).
- **Every other `key = value` is a ghostty directive**, forwarded verbatim to
  libghostty via `TerminalConfiguration.withCustom` — so a user can paste an
  existing ghostty config straight in (no prefix; we do NOT read the external
  `~/.config/ghostty/config`). Ghostty defines none of the reserved keys, so no
  collision. Comments are **full-line only** (`#` at line start) so `#`-prefixed
  color values survive.
- **Ghostty validates all-or-nothing** — `TerminalController.prepareConfig`
  frees the WHOLE config if any key yields a diagnostic, so a single stray
  directive silently drops every custom setting *including the per-surface
  `command`*, which strands preserved sessions (panes launch plain shells).
  Two guards, both regression-tested: `AppConfig.isReservedButUnsupported`
  swallows Zetty's own keys this build lacks (the `zetty-` namespace — which
  **all new keys must use** — plus the grandfathered `notify-` one and
  `retiredReservedKeys`; add a retired key there, don't just delete its
  `case`, since deleting it makes old configs *forward* the key rather than
  ignore it. They're recorded in `unsupportedKeys` and dropped by `rendered()`),
  and `SurfaceRegistry.pair(for:)` retries with a Zetty-only config when
  `setTerminalConfiguration` returns false, reporting via
  `onConfigurationRejected` → one-time alert. Real cause of a
  4-relaunch session-loss incident (`notify-poke` from a feature branch).
- **Precedence:** scheme theme → pasted ghostty directives (last wins). Pasted
  directives may override terminal colors; the app chrome stays scheme-driven.
- **Reload:** ⇧⌘, (also App menu + command palette) re-reads config and
  re-applies theme + terminal overrides to every live pane. Runtime scheme /
  appearance switches persist back to the file (`AppConfig.rendered()`).
- **`preserve-sessions = true|false`** (default false) — panes run inside
  [zmx](https://zmx.sh) sessions so they survive quit/relaunch. The reattach,
  scrollback-restore, scratch-pane deadlock, title persistence and restart-
  recovery rules are in `.hydra/rules/session-preservation.md` — read it before
  touching anything session-related.

## Chrome refresh  ← read before touching the tab bar / sidebar / status bar

Agent CLIs animate a spinner glyph **in their terminal title**, so every frame
is a title escape sequence. Refreshing the chrome synchronously per event once
put 59% of the main thread in Auto Layout and leaked ~550 MB of AppKit KVO
records over two days (1.2 GB footprint, 2.8 GB peak, CPU pinned near 100%).
Three rules keep it flat; breaking any one reintroduces the whole class of bug:

1. **Machine-driven refreshes coalesce.** Terminal titles, the
   foreground-process probe and agent hook events call
   `TerminalViewController.setNeedsChromeRefresh(tabBar:sidebar:)`, which
   refreshes ONCE ~0.1s later. Only user-driven changes call
   `refreshTabBar()`/`refreshSidebar()` directly (same run-loop turn, so input
   still feels immediate). `SurfaceRegistry`'s title subscription also
   `removeDuplicates()` — `combineLatest` re-emits when *either* of title/cwd
   fires, so an unchanged republish used to wake everything.
2. **Every view-layer `update(...)` no-ops on unchanged input.**
   `SidebarProject` is `Equatable` for exactly this (`NSImage`/`NSColor` compare
   via `isEqual:`, and `AgentIcons` caches logos so an unchanged icon is the
   same instance); `TabBarView` caches its last titles/icons/selection and
   re-renders pills **in place** when only content moved, instead of
   destroying and rebuilding every pill's constraints.
   **Corollary — a scheme change must invalidate those caches**, because the
   inputs are equal and only the colors differ: `StatusBarView.applyTheme`
   calls `invalidateRenderCaches()`, `TabBarView.applyTheme` calls
   `item.restyle()` per pill, and `SidebarView.applyTheme` calls
   `rebuildOutline()`. Forget one and that widget freezes in the old palette.
3. **A re-render must never move the sidebar scroller.**
   `rebuildOutline()` calls `scrollRowToVisible` only when the *logical*
   selection (project + tab, not the row index — rows shift when a section
   collapses) actually changed. Unconditional scrolling made the sidebar
   impossible to scroll while any agent was running: it snapped back to the
   active project several times a second.

The layout rules for the chrome (tab strip, window floor, status bar
compaction, command palette, sidebar drawer) are in
`.hydra/rules/chrome-layout.md`; memory, surface and session-lifetime rules
are in `.hydra/rules/surfaces-and-memory.md`.

## Conventions

- Follow existing file patterns; keep files focused. `ZettyCore` stays pure
  (no AppKit import).
- **Don't use the `impeccable` skill or its sub-commands in this repo** (that
  includes `clarify`, `polish`, `critique`, `audit`, and the rest). Its pipeline
  expects a web surface and wants to generate `PRODUCT.md`, surface briefs, and
  a detector hook that don't fit a native AppKit terminal app. The visual
  authority here is [`DESIGN.md`](DESIGN.md) plus `ZTheme`; do UI and copy work
  directly against those.
- **Never add a keyboard shortcut without first proving the chord is free.**
  Zetty has four independent shortcut surfaces, and a silent collision is the
  usual failure — AppKit just lets the first responder win, so the new binding
  "sometimes doesn't work". Before adding one, check **all four**:

  ```sh
  # 1. Native menu key equivalents (character + modifier mask must BOTH match
  #    an existing pair to collide — ⌘B, ⌃⇧B and ⇧⌘B are three distinct chords)
  grep -B4 'keyEquivalentModifierMask' App/Sources/App/AppDelegate.swift \
    | grep -E 'title:|keyEquivalent'
  # 2. Prefix layer (Ctrl+B then a key)
  grep -n 'bind("' Sources/ZettyCore/Keybindings/BindingCommand.swift
  # 3. Copy mode
  grep -n 'copyBind\|defaultCopyTable' -A40 Sources/ZettyCore/Keybindings/BindingCommand.swift
  # 4. The user's own config — `bind` / `copy-bind` lines are additive
  grep -E '^(prefix|bind|copy-bind)' ~/.config/zetty/config
  ```

  Then state the result before writing code, and say what the chord costs.
  Two costs are easy to miss:

  - **A native equivalent is resolved in `NSApplication.sendEvent` *before* the
    terminal surface sees the event**, so a Control-modified chord bound here
    permanently stops that keystroke reaching the pty. Prefer ⌘-based chords for
    menu items — Command is never sent to the shell — and leave Control chords
    to the prefix layer.
  - **A well-known chord spent here is spent for good.** Say what else it
    conventionally means and let the user decide. Recorded precedent: ⇧⌘F is
    "find in files" in VS Code and Zed, and it is deliberately spent on Toggle
    File Tree; a future project-wide content search needs a different chord
    rather than stealing this one back. ⇧⌘G is spent on Toggle Tile Mode,
    costing find-previous and Finder's Go to Folder — plain ⌘G was left free on
    purpose, for the viewer's deferred find-in-file. ⇧⌘J is spent on the tile
    manager, beside ⌘J for Sessions (the two docked drawers), costing Chrome's
    Downloads and Xcode's Reveal in Project Navigator.
- Do not commit debug `NSLog`/`print` statements.
- Never commit or push without being asked; never add `Co-Authored-By` or a
  session link to commit messages.
- **Don't create a git branch unless it's implied.** Work directly on the
  current branch (usually `main`) by default; only branch out when the user
  asks for one or the task clearly calls for it (e.g. a PR workflow). This
  overrides any workflow skill that would auto-branch before implementing.
- **Document every new feature or user-facing change in `README.md`** (its
  usage — Features, shortcuts, Configuration, and/or the Control CLI list) as
  part of the same change. A feature isn't done until the README covers it.
- **Feature deep-dives live in `.hydra/rules/`, not here.** Claude Code caps
  the loaded instruction files at 150k chars, and this file once exceeded it.
  Keep only cross-cutting rules in `CLAUDE.md`; record a feature's gotchas in
  its rule file (or a new one via `hydra add` / `hydra new`) and run
  `hydra sync` so the index below stays current.
- **Keep `CLAUDE.md` and `AGENTS.md` byte-identical.** They share one canonical
  content; any edit to one must be replicated to the other in the same commit.
- **Every release ships human-written notes.** When cutting a release, add a
  note to the GitHub release body summarizing the updates and new features it
  introduces — a short, user-facing "What's new" list, not just the
  auto-generated "Full Changelog" link. Group by feature/fix and phrase it for
  users, mirroring the same changes documented in `README.md`.

## Installing after a change  ← not optional, and not only for releases

**Every feature, fix or dependency bump ends with the running app on the new
build.** Glen runs `/Applications/zetty.app`, so work that only reached
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
- **For a release, install the Release build** (`build/Build/Products/Release/`
  from `package.sh`), so `/Applications` matches the shipped DMG.
- **A dependency bump counts as a change.** `swift test` covers only the pure
  `ZettyCore` target and never links libghostty, so a bump that compiles is
  still unverified — the installed app being exercised is the verification.

## Releasing  ← use `scripts/release.sh`, not a generic release tool

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
log — see the human-written-notes rule above.

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

Signing: builds are **ad-hoc signed** (no Developer ID yet), so a downloaded
DMG is quarantined and recipients must run `xattr -d com.apple.quarantine
/Applications/zetty.app` once. In-app updates skip that. Swap in Developer ID
signing + notarization in `scripts/package.sh` when an Apple account exists.

<!-- hydra:rules:start -->
## Rules

**Before you enter plan mode, run a command, or create/edit a file, you MUST
first:** find the index rows whose trigger, glob, or command covers what you are
about to do and read those rule files, then run
`grep -rin '<keyword>' .hydra/rules` to catch what the index alone misses. Do not act
until you are following every matching rule.

Project rules override global rules on conflict.

### Rules index

| Applies when | Matches (path glob / command) | Rule |
| --- | --- | --- |
| adding or changing agent accounts or logins · supporting a new agent harness for accounts · CLAUDE_CONFIG_DIR or CODEX_HOME handling | `Sources/ZettyCore/Accounts/**` · `App/Sources/App/AccountSeeder.swift` · `App/Sources/App/AccountShimInstaller.swift` · `App/Sources/App/AddAccountSheet.swift` · `App/Sources/App/AgentAuthRunner.swift` · `App/Sources/App/HookInstaller.swift` · `zetty run` · `zetty accounts` | .hydra/rules/agent-accounts.md |
| changing agent status dots, hooks, or needs-attention notifications | `Sources/ZettyCore/Agents/**` · `App/Sources/App/AgentEventWatcher.swift` · `App/Sources/App/HookInstaller.swift` | .hydra/rules/agent-detection.md |
| changing the pane refresh button or restarting an agent in place | `App/Sources/App/Tiles/ReloadingOverlay.swift` · `App/Sources/App/Tiles/RefreshSpinner.swift` · `App/Sources/App/Tiles/AgentRestartPresenting.swift` · `Sources/ZettyCore/Recovery/AgentResume.swift` | .hydra/rules/agent-pane-refresh.md |
| changing the tab bar, status bar, sidebar, or command palette · the window refuses to resize or its minimum size grows · adding an overlay or anything inside the main window | `App/Sources/App/TabBarView.swift` · `App/Sources/App/StatusBarView.swift` · `App/Sources/App/SidebarView.swift` · `App/Sources/App/SidebarDrawer.swift` · `App/Sources/App/CommandPaletteView.swift` · `Sources/ZettyCore/StatusBar/**` · `Sources/ZettyCore/Support/CommandSearch.swift` · `Sources/ZettyCore/Support/FuzzyMatch.swift` · `Sources/ZettyCore/Model/SidebarMetrics.swift` | .hydra/rules/chrome-layout.md |
| adding or changing a zetty CLI verb · changing the control socket or StatusSnapshot | `Sources/ZettyCore/CLI/**` · `App/Sources/App/ControlSocketServer.swift` · `App/Sources/App/CLILink.swift` · `App/Sources/App/main.swift` | .hydra/rules/control-cli.md |
| changing the per-pane file tree | `Sources/ZettyCore/FileTree/**` · `App/Sources/App/FileTree/**` | .hydra/rules/file-tree.md |
| changing the file viewer peek or cmd-click path handling · the file viewer shows a blank panel · opening files from terminal output | `Sources/ZettyCore/Viewer/**` · `Sources/ZettyCore/Diagnostics/**` · `App/Sources/App/FileViewerLoader.swift` · `App/Sources/App/FileViewerOverlay.swift` · `App/Sources/App/PathHoverTracker.swift` · `App/Sources/App/ZettyLog.swift` · `zetty view` | .hydra/rules/file-viewer.md |
| changing the Home project or zetty-home-path · removing, hibernating, or restoring projects | — | .hydra/rules/home-project.md |
| changing prefix keys, key bindings, or copy mode · adding a keyboard shortcut | `Sources/ZettyCore/Keybindings/**` · `App/Sources/App/KeyInterceptor.swift` · `App/Sources/App/CopyModeController.swift` | .hydra/rules/keybindings-copy-mode.md |
| changing project clones, merge-back, or clone removal | `Sources/ZettyCore/Clone/**` · `App/Sources/App/CloneRunner.swift` · `App/Sources/App/CloneWarningBanner.swift` · `App/Sources/App/CloneMergeGuideView.swift` · `App/Sources/App/FileCopyBackRunner.swift` · `App/Sources/App/FileCopyBackSheet.swift` · `zetty clone` · `zetty update-clone` · `zetty remove-project` | .hydra/rules/project-clones.md |
| changing per-project settings, color, icon, or theme overrides · layout templates or .zetty/project.json · per-project env vars or startup commands | `Sources/ZettyCore/Settings/**` · `App/Sources/App/ProjectSettingsSheet.swift` · `App/Sources/App/IconPicker.swift` | .hydra/rules/project-settings.md |
| changing preserve-sessions or zmx session handling · restart recovery or resuming agents after a power-off · a preserved pane reattaches wrong, loses scrollback, or launches a plain shell · changing scratch panes or how sessions are reaped | `Sources/ZettyCore/Session/**` · `Sources/ZettyCore/Recovery/**` · `App/Sources/App/ZmxRunner.swift` · `App/Sources/App/ScrollbackRestore.swift` · `App/Sources/App/RestartRecoveryRunner.swift` · `App/Sources/App/AgentSessionLookup.swift` · `zmx ` · `zetty quit` | .hydra/rules/session-preservation.md |
| changing the Sessions view or task manager · killing or interrupting sessions from the UI | `Sources/ZettyCore/Monitor/**` · `App/Sources/App/SessionSampler.swift` · `App/Sources/App/SessionsView.swift` · `App/Sources/App/TaskManagerWindowController.swift` · `App/Sources/App/ProcessFootprint.swift` | .hydra/rules/session-task-manager.md |
| changing sidebar sections, Spaces, or project ordering · drag-and-drop in the sidebar | `Sources/ZettyCore/Model/Space.swift` · `App/Sources/App/SpaceSheet.swift` · `App/Sources/App/SidebarView.swift` · `zetty new-space` · `zetty rename-space` · `zetty remove-space` · `zetty move-to-space` | .hydra/rules/spaces.md |
| handling ssh:// URLs or other URL schemes · an external open lands in the wrong app copy (Launch Services) | `Sources/ZettyCore/CLI/SSHURLHandler.swift` | .hydra/rules/ssh-url-handover.md |
| investigating a memory or leak report · adding a pane close path or changing when surfaces are freed · changing hibernation or registry prune | `App/Sources/ZettyGhostty/**` · `App/Sources/App/ProcessFootprint.swift` · `Sources/ZettyCore/Session/BackgroundPanePolicy.swift` | .hydra/rules/surfaces-and-memory.md |
| changing tab titles, tool logos, or the foreground-process probe · adding a bundled logo for a tool | `Sources/ZettyCore/Model/TabTitle.swift` · `Sources/ZettyCore/Session/ForegroundProcess.swift` · `Sources/ZettyCore/Agents/*ForegroundProcessProbe.swift` · `App/Sources/App/AgentIcons.swift` · `App/Resources/AgentLogos/**` | .hydra/rules/tab-identity.md |
| changing tile mode, tile views, or tile profiles | `Sources/ZettyCore/Tiles/**` · `App/Sources/App/Tiles/**` · `zetty tiles` | .hydra/rules/tile-mode.md |
<!-- hydra:rules:end -->
