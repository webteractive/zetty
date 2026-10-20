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

## Every change  ← always applies; the details are in the rules named

- **Before starting any feature, fix or other change, run
  `scripts/check-libghostty.sh`** (once per working session) and state the
  result in the summary: "libghostty is current", or what is newer. Exit 2
  means GitHub could not be reached, which is not "up to date". Anything
  newer: read `libghostty-bump.md` before touching the pin.
- **Verify before the commit in the isolated test app**
  (`isolated-test-app.md`), never by quitting or replacing
  `/Applications/zetty.app`.
- **After the commit, install the new build and relaunch, without asking**
  (`install-after-change.md`): build after committing, `ditto` in place, and
  confirm this session's surface is tracked before `zetty quit`.
- **UI follows the design rules** (`design-rules.md`, visual spec in
  [`DESIGN.md`](DESIGN.md)): never hardcode a color; chrome uses
  `ZTheme.chromeFont`, only the terminal and status bar the mono font.
- **Machine-driven chrome refreshes coalesce** through
  `setNeedsChromeRefresh` (`chrome-refresh.md`).
- **A new config key uses the `zetty-` namespace and ships with a Settings
  control** (`configuration.md`).
- **A new keyboard shortcut needs proof its chord is free** on all four
  shortcut surfaces (`keybindings-copy-mode.md`).
- **Anything new that ships in the app needs its license** in
  `THIRD_PARTY_NOTICES.md` and `licenses/`, every libghostty bump included
  (`third-party-notices.md`).
- **Release only with `scripts/release.sh` and human-written notes**
  (`releasing.md`): a generic release tool silently ships a broken release.

## Conventions

- Follow existing file patterns; keep files focused. `ZettyCore` stays pure
  (no AppKit import).
- **Don't use the `impeccable` skill or its sub-commands in this repo** (that
  includes `clarify`, `polish`, `critique`, `audit`, and the rest). Its pipeline
  expects a web surface and wants to generate `PRODUCT.md`, surface briefs, and
  a detector hook that don't fit a native AppKit terminal app. The visual
  authority here is [`DESIGN.md`](DESIGN.md) plus `ZTheme`; do UI and copy work
  directly against those.
- Do not commit debug `NSLog`/`print` statements.
- Never commit or push without being asked; never add `Co-Authored-By` or a
  session link to commit messages.
- **Don't create a git branch unless it's implied.** Work directly on the
  current branch (usually `main`) by default; only branch out when the user
  asks for one or the task clearly calls for it (e.g. a PR workflow). This
  overrides any workflow skill that would auto-branch before implementing.
- **Document every new feature or user-facing change in `README.md`** (its
  usage — the intro list, Using Zetty, shortcuts, Configuration, and/or the
  Control CLI list) as part of the same change. A feature isn't done until the
  README covers it. **The README is usage only**: how to reach a feature and
  what it does, in a few lines. Rationale, edge cases and internals go in the
  feature's `.hydra/rules/` file; building, testing and releasing go in
  `DEVELOPMENT.md`. (It was trimmed from ~1,180 lines to ~360 on 2026-10-07.)
- **Feature deep-dives live in `.hydra/rules/`, not here.** Claude Code caps
  the loaded instruction files at 150k chars, and this file once exceeded it.
  Keep only cross-cutting rules in `CLAUDE.md`; record a feature's gotchas in
  its rule file (or a new one via `hydra add` / `hydra new`) and run
  `hydra sync` so the index below stays current.
- **Keep `CLAUDE.md` and `AGENTS.md` byte-identical.** They share one canonical
  content; any edit to one must be replicated to the other in the same commit.

<!-- hydra:rules:start -->
## Rules

**Before you enter plan mode, run a command, or create/edit a file, you MUST
first:** find the index rows whose trigger, glob, or command covers what you are
about to do and read those rule files, then run
`grep -rin '<keyword>' .hydra/rules` to catch what the index alone misses. Do not act
until you are following every matching rule.

Project rules override global rules on conflict.

### Rules index

Rule files are in `.hydra/rules`.

| Applies when | Matches (path glob / command) | Rule |
| --- | --- | --- |
| adding or changing agent accounts or logins · supporting a new agent harness for accounts · CLAUDE_CONFIG_DIR or CODEX_HOME handling | `Sources/ZettyCore/Accounts/**` · `App/Sources/App/AccountSeeder.swift` · `App/Sources/App/AccountShimInstaller.swift` · `App/Sources/App/AddAccountSheet.swift` · `App/Sources/App/AgentAuthRunner.swift` · `App/Sources/App/HookInstaller.swift` · `zetty run` · `zetty accounts` | agent-accounts.md |
| changing agent status dots, hooks, or needs-attention notifications | `Sources/ZettyCore/Agents/**` · `App/Sources/App/AgentEventWatcher.swift` · `App/Sources/App/HookInstaller.swift` | agent-detection.md |
| handing a pane's work to a fresh agent session or another account · changing /z-handoff, the pane's handoff button, or zetty handoff | `Sources/ZettyCore/Transfer/**` · `App/Sources/App/TerminalViewController+AgentHandoff.swift` · `zetty handoff` | agent-handoff.md |
| changing the pane refresh button or restarting an agent in place | `App/Sources/App/Tiles/ReloadingOverlay.swift` · `App/Sources/App/Tiles/RefreshSpinner.swift` · `App/Sources/App/Tiles/AgentRestartPresenting.swift` · `Sources/ZettyCore/Recovery/AgentResume.swift` | agent-pane-refresh.md |
| changing the tab bar, status bar, sidebar, or command palette · the window refuses to resize or its minimum size grows · adding an overlay or anything inside the main window | `App/Sources/App/TabBarView.swift` · `App/Sources/App/StatusBarView.swift` · `App/Sources/App/SidebarView.swift` · `App/Sources/App/SidebarDrawer.swift` · `App/Sources/App/CommandPaletteView.swift` · `Sources/ZettyCore/StatusBar/**` · `Sources/ZettyCore/Support/CommandSearch.swift` · `Sources/ZettyCore/Support/FuzzyMatch.swift` · `Sources/ZettyCore/Model/SidebarMetrics.swift` | chrome-layout.md |
| refreshing the tab bar, sidebar or status bar from a title, hook or probe event · adding a color scheme or changing a widget's applyTheme · high CPU, memory growth or a sidebar that will not scroll while agents run | `App/Sources/App/TabBarView.swift` · `App/Sources/App/StatusBarView.swift` · `App/Sources/App/SidebarView.swift` · `App/Sources/App/Tiles/TileGridView.swift` | chrome-refresh.md |
| changing any file of a mod under Mods/ — bump version in its plugin.json in the same change · changing Zetty's Claude Code mod or what it reports · adding chrome fed by agent usage (rate limits, cost, context, turn outcome) | `Mods/**` · `Sources/ZettyCore/Agents/AgentUsage.swift` · `Sources/ZettyCore/Agents/ModInstall.swift` · `App/Sources/App/AgentUsageWatcher.swift` · `App/Sources/App/ModInstaller.swift` · `Sources/ZettyCore/Accounts/AccountLimits.swift` · `claude plugin validate` · `claude plugin test` | claude-mod.md |
| adding, retiring or changing a config key · changing how the config file is parsed, applied or reloaded · custom ghostty directives or the per-surface command are silently dropped | `Sources/ZettyCore/Config/**` · `App/Sources/App/SettingsWindowController.swift` · `zetty reload` | configuration.md |
| adding or changing a zetty CLI verb · changing the control socket or StatusSnapshot | `Sources/ZettyCore/CLI/**` · `App/Sources/App/ControlSocketServer.swift` · `App/Sources/App/CLILink.swift` · `App/Sources/App/main.swift` | control-cli.md |
| adding or changing any UI: chrome, dialogs, sheets, colors or fonts · adding or changing a color scheme or theme token | `App/Sources/App/Theme.swift` · `DESIGN.md` · `App/Sources/App/**/*View.swift` · `App/Sources/App/**/*Sheet.swift` · `App/Sources/App/**/*Overlay.swift` · `App/Sources/App/**/*WindowController.swift` | design-rules.md |
| changing the per-pane file tree | `Sources/ZettyCore/FileTree/**` · `App/Sources/App/FileTree/**` | file-tree.md |
| changing the file viewer peek or cmd-click path handling · the file viewer shows a blank panel · opening files from terminal output | `Sources/ZettyCore/Viewer/**` · `Sources/ZettyCore/Diagnostics/**` · `App/Sources/App/FileViewerLoader.swift` · `App/Sources/App/FileViewerOverlay.swift` · `App/Sources/App/PathHoverTracker.swift` · `App/Sources/App/ZettyLog.swift` · `zetty view` | file-viewer.md |
| changing hibernation handoffs or hibernate-after eligibility · a hibernated pane wakes without its handoff, or into the wrong conversation · a project with an idle agent is not auto-hibernated, or a busy one is | `Sources/ZettyCore/Hibernation/**` · `App/Sources/App/Handoff*.swift` · `App/Sources/App/AgentTranscript.swift` · `App/Sources/App/TerminalViewController+Handoffs.swift` · `zetty hibernate` · `zetty wake` | hibernation-handoffs.md |
| changing the Home project or zetty-home-path · removing, hibernating, or restoring projects | — | home-project.md |
| finishing a committed feature, fix or dependency bump · installing a build into /Applications/zetty.app | `ditto ` · `open -a /Applications/zetty.app` · `zetty quit` | install-after-change.md |
| verifying a change in the running app before it is committed · driving the app to check a feature or a fix (/verify, prepare-for-release) · trying anything that quits, hibernates, closes panes or ends sessions | `zetty quit` · `ditto ` · `open -a /Applications/zetty.app` | isolated-test-app.md |
| changing prefix keys, key bindings, or copy mode · adding a keyboard shortcut | `Sources/ZettyCore/Keybindings/**` · `App/Sources/App/KeyInterceptor.swift` · `App/Sources/App/CopyModeController.swift` | keybindings-copy-mode.md |
| check-libghostty reports a newer libghostty than the pin · bumping the libghostty-spm pin in Project.swift | `.package.resolved` · `scripts/check-libghostty.sh` | libghostty-bump.md |
| changing project clones, merge-back, or clone removal | `Sources/ZettyCore/Clone/**` · `App/Sources/App/CloneRunner.swift` · `App/Sources/App/CloneWarningBanner.swift` · `App/Sources/App/CloneMergeGuideView.swift` · `App/Sources/App/FileCopyBackRunner.swift` · `App/Sources/App/FileCopyBackSheet.swift` · `zetty clone` · `zetty update-clone` · `zetty remove-project` | project-clones.md |
| changing per-project settings, color, icon, or theme overrides · layout templates or .zetty/project.json · per-project env vars or startup commands | `Sources/ZettyCore/Settings/**` · `App/Sources/App/ProjectSettingsSheet.swift` · `App/Sources/App/IconPicker.swift` | project-settings.md |
| cutting a release or writing its notes · changing packaging, signing, notarization or the self-updater | `scripts/release.sh` · `scripts/package.sh` · `Sources/ZettyCore/Update/**` · `App/Sources/App/UpdateChecker.swift` · `App/Sources/App/UpdateInstaller.swift` · `scripts/release.sh` · `scripts/package.sh` | releasing.md |
| changing preserve-sessions or zmx session handling · restart recovery or resuming agents after a power-off · a preserved pane reattaches wrong, loses scrollback, or launches a plain shell · changing scratch panes or how sessions are reaped | `Sources/ZettyCore/Session/**` · `Sources/ZettyCore/Recovery/**` · `App/Sources/App/ZmxRunner.swift` · `App/Sources/App/ScrollbackRestore.swift` · `App/Sources/App/RestartRecoveryRunner.swift` · `App/Sources/App/AgentSessionLookup.swift` · `zmx ` · `zetty quit` | session-preservation.md |
| changing the Sessions view or task manager · killing or interrupting sessions from the UI | `Sources/ZettyCore/Monitor/**` · `App/Sources/App/SessionSampler.swift` · `App/Sources/App/SessionsView.swift` · `App/Sources/App/TaskManagerWindowController.swift` · `App/Sources/App/ProcessFootprint.swift` | session-task-manager.md |
| changing sidebar sections, Spaces, or project ordering · drag-and-drop in the sidebar | `Sources/ZettyCore/Model/Space.swift` · `App/Sources/App/SpaceSheet.swift` · `App/Sources/App/SidebarView.swift` · `zetty new-space` · `zetty rename-space` · `zetty remove-space` · `zetty move-to-space` | spaces.md |
| handling ssh:// URLs or other URL schemes · an external open lands in the wrong app copy (Launch Services) | `Sources/ZettyCore/CLI/SSHURLHandler.swift` | ssh-url-handover.md |
| investigating a memory or leak report · adding a pane close path or changing when surfaces are freed · changing hibernation or registry prune | `App/Sources/ZettyGhostty/**` · `App/Sources/App/ProcessFootprint.swift` · `Sources/ZettyCore/Session/BackgroundPanePolicy.swift` | surfaces-and-memory.md |
| changing tab titles, tool logos, or the foreground-process probe · adding a bundled logo for a tool | `Sources/ZettyCore/Model/TabTitle.swift` · `Sources/ZettyCore/Session/ForegroundProcess.swift` · `Sources/ZettyCore/Agents/*ForegroundProcessProbe.swift` · `App/Sources/App/AgentIcons.swift` · `App/Resources/AgentLogos/**` | tab-identity.md |
| adding a package, bundled file, font, logo set or script to the app · bumping libghostty | `THIRD_PARTY_NOTICES.md` · `licenses/**` · `App/Resources/**` · `Package.swift` | third-party-notices.md |
| changing tile mode, tile views, or tile profiles | `Sources/ZettyCore/Tiles/**` · `App/Sources/App/Tiles/**` · `zetty tiles` | tile-mode.md |
<!-- hydra:rules:end -->
