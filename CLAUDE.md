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

The Xcode project is **Tuist-generated**. Sources are listed explicitly, so
**after adding or removing a file you must regenerate**:

```sh
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
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
2. **Fonts follow content:** terminal-adjacent UI (tabs, project tree, status
   bar, kbd chips) uses `ZTheme.monoFont`; prose and standard controls use the
   system font.
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
- **Precedence:** scheme theme → pasted ghostty directives (last wins). Pasted
  directives may override terminal colors; the app chrome stays scheme-driven.
- **Reload:** ⇧⌘, (also App menu + command palette) re-reads config and
  re-applies theme + terminal overrides to every live pane. Runtime scheme /
  appearance switches persist back to the file (`AppConfig.rendered()`).
- **`preserve-sessions = true|false`** (default false) — panes run inside
  [zmx](https://zmx.sh) sessions (`zmx attach zetty-<uuid8>`, one per pane) so
  they survive app quit/relaunch; reattach replays terminal state. Quit
  survives, explicit close kills (via `registry.prune` → `zmx kill`); a
  one-shot startup reap kills `zetty-*` sessions no restored surface owns
  (crash leftovers), and Settings offers a manual kill too. The
  Settings (⌘,) toggle offers to download the zmx release binary from zmx.sh
  into `~/.zetty/bin` when missing (Homebrew/manual installs are detected
  too); config-only enablement without zmx falls back to plain shells with a
  one-time alert. Pure logic in
  `ZettyCore` (`SessionPersistence`); process IO in `ZmxRunner`.
  Reattach gotchas handled in the app layer:
  - **`ZMX_SESSION` is stripped** from the attach command (`env -u`) and from
    every zmx subprocess: inherited from a zmx-backed terminal (Supacode, or
    Zetty itself), `zmx attach` would *kill* that session instead of
    attaching the target.
  - **Repaint nudge** — zmx replays screen contents but a running TUI paints
    only deltas, so a reattached pane stays half-drawn; ~1s after a pane's
    surface appears it is shrunk ~20pt and restored (SIGWINCH → full repaint).
  - **Scrollback restore** — `restore-scrollback` (default true): panes launch
    through a generated wrapper (`~/.zetty/scrollback-restore.sh`, contents in
    `SessionPersistence.restoreScriptContents`, written idempotently by
    `ScrollbackRestore.ensureScript()`) that replays `zmx history <session>
    --vt` into the surface before exec'ing the attach — full scrollback with
    attributes survives quit/relaunch. Plain-token invocation (`/bin/sh
    <script> <zmx> <session>`) because ghostty's `command` parser can't be
    relied on for quote grouping; the script's `unset ZMX_SESSION` covers the
    strip for both zmx calls. Script write failure falls back to the bare
    attach (session preserved, replay lost).
  - **Title persistence** — zmx never replays the title escape sequence, so
    each surface's last emitted title persists as `Surface.lastTitle` in
    `workspace.json` and seeds the tab name until the program emits a fresh
    one (`SurfaceRegistry.title` returns nil for the empty initial title so
    the fallback engages).

### Home project

A permanent **Home** project (`ProjectRuntime.isHome`) is seeded by default
(`WorkspaceModel.init()` / `makeHome()`, rooted at `~`). It renders as a single
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
(`WorkspaceModel.restored(from:activeIndex:)`), so existing users' old
home-rooted project stays as an ordinary, now-removable project. Home's
settings are keyed by the reserved sentinel `ProjectSettingsStore.homeKey`
(`@home`) via `ProjectRuntime.settingsKey`, so they never collide with a
user-added `~` project. `isHome` is persisted in `workspace.json`.

### Per-project settings

Right-click a project row → **Rename…** / **Project Settings…** (name, curated
color, SF Symbol icon, preserve-sessions + notifications tri-states). Pure
model in `ZettyCore/Settings/` (`ProjectSettings` · `ProjectSettingsFile` ·
`ProjectSettingsStore` · `ProjectSettingsResolver`); private JSON at
`~/Library/Application Support/zetty/project-settings.json` keyed by
**canonical rootPath** (survives remove/re-add; a moved directory orphans its
settings — accepted for v1). Precedence: project override → global config →
default. App wiring: `AppDelegate.resolvedSettings(for:)` +
`updateProjectSettings(_:for:)`; per-pane preserve decision inside
`applySessionPreservation`'s provider via `WorkspaceModel.project(containing:)`
(affects NEW panes only); notification gating at the fire site
(sound/banners) and in `publishAttentionCount` (dock badge) — the in-app
bell/inbox and status dots are never gated. Palette ids in
`ZTheme.projectPalette` (8 curated hues, distinct from accent + semantic
status colors, appearance-reactive: each id carries a dark/light hex pair).

v2/v3 additions (same design doc):
- **Appearance + theme overrides** — modeled on the global keys:
  `ProjectSettings.appearanceOverride` ("system"/"dark"/"light") +
  `themeDarkOverride`/`themeLightOverride` (scheme per axis), each
  independently nil = follow global. Resolved in
  `AppDelegate.applyThemeForActiveProject()` — the single visual decision
  point (transient, never persisted into the global config; unknown scheme
  names fall back to the global choice; it also pins/releases
  `NSApp.appearance` for the EFFECTIVE axis). Activation hook:
  `TerminalViewController.onActiveProjectChanged` (project select — incl.
  tab-row clicks that switch projects — add, remove). OS appearance flips
  arrive via a distributed-notification observer (KVO on
  `effectiveAppearance` goes silent while pinned), and `osIsDark` reads the
  system default when pinned so a pinned project can't poison the next
  project's resolution.
- **Layout templates** — `LayoutTemplate`/`TemplateNode` (pure, mirrors
  `SurfaceNode`; panes carry root-relative cwds + startup commands;
  `capture(from:rootPath:)` / `tabList(rootPath:)`). Storage: the
  `layoutTemplate` field of the git-committable `.zetty/project.json`
  (`ProjectFile`/`ProjectFileIO` — shareable keys ONLY: layoutTemplate,
  startupCommand, envNames; no env-values field exists, and a hand-edited one
  is dropped on read) with a global fallback (`LayoutTemplateStore`,
  `layout-template.json` in App Support). Applied on `add-project` (replaces
  the single-pane seed) or on demand from the sheet's Layout row
  (Save Current / Apply / Clear). Startup commands inject once via
  `registry.sendText` ~0.8s after the pane spawns
  (`pendingStartupCommands`, in-memory only — a relaunch never re-runs
  commands into preserved sessions).
- **Env vars** — `ProjectSettings.env` (values in the PRIVATE store only);
  injected as repeated ghostty `env` directives per surface
  (`SurfaceRegistry.surfaceEnvironment` → `config.custom("env", "K=V")`).
  New panes only — a preserved zmx session captures env at first creation.
  Sheet editor: KEY=VALUE lines.

### Project clones

An instant APFS copy-on-write fork of a project — untracked files, `.env`,
`node_modules` all included — checked out onto its own git branch. Persisted
as `cloneSource: String?` (the source's canonical rootPath, nil for ordinary
projects) on `Project`/`ProjectRuntime`, decoded tolerantly like `isHome` so
old `workspace.json` files load unchanged.

The split mirrors `GitStatus`: pure planning in `CloneSupport`
(`ZettyCore/Clone/`) — `ClonePlan` (target path under
`~/.zetty/clones/<slug(source)>-<name>`, branch `zetty/<name>`, display name
`<source>/<name>`), name validation/slugging, git argument builders, and the
removal classifier (`CloneWorkState`: clean / unfetched / dirty) — versus
process IO in the app-layer `CloneRunner` (`cp -Rc` with a `cp -R` fallback
for non-APFS volumes, `git switch -c`, fetch-back, branch/dirty probes,
guarded delete).

`clone` is a **slow verb**: `AppDelegate.startControlSocket` special-cases it
(alongside `capture`/`quit`) to plan on main (workspace state), copy on the
socket queue (a non-APFS fallback `cp -R` can be slow), then register on main
— `handleOnMain`'s default switch deliberately errors if one of these three
lands there ("internal: slow verb routed to the main handler").

Removal (`CloneRunner.fetchBack`, wired from both `zetty remove-project
--fetch` and the GUI's Remove Clone… dialog) runs `git fetch <clonePath>
<branch>:<branch>` in the SOURCE repo; a failure aborts before anything is
deleted — nothing is lost on a bad fetch. Deletion itself is guarded by
`CloneSupport.isSafeToDelete` — strictly inside `~/.zetty/clones/`, never the
root itself, no `..` traversal.

Clones inherit the source project's settings and offer no Project Settings…
of their own (the sidebar context menu hides it — a clone-owned settings
file would break inheritance). `AppDelegate.resolvedSettings(for:)` falls
back to the source's settings with `name` and `icon` cleared (an inherited
name would rename the clone to match its source; an inherited icon would
suppress the fork glyph that marks the row as a clone). A clone-keyed
settings entry, if one ever exists on disk, still wins wholesale.

The clone sheet (`promptCloneProject`) shows an **Open with** picker when the
SOURCE project has agents set (`agentsProvider`, Project Settings → Agents):
each enabled agent plus "Standard session", defaulting to the first agent.
The pick's command threads through `registerClone(plan:outcome:focus:startupCommand:)`
into `pendingStartupCommands` BEFORE the pane spawns — the same injection
path as the new-pane agent chooser. CLI `zetty clone` never injects a
command.

Limits: no clones of clones (`cloneSource == nil` required on the source),
Home/Scratch can't be cloned. `WorkspaceModel.regroup()` slots each clone row
immediately after its source in sidebar/CLI order; an orphaned clone (source
removed) falls back to an ordinary position.

### `ssh://` URL handover

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

## tmux-style prefix keys + copy mode

`Ctrl+B` (configurable) arms a one-shot prefix; the next key drives Zetty:
`%`/`"` split · h/j/k/l or arrows focus panes directionally · `o` cycle ·
`x` close · `z` zoom (transient, never persisted) · `c`/`n`/`p`/`1-9` tabs ·
`,` inline tab rename · `[` copy mode · `]` paste · prefix-twice sends the
literal prefix to the pty · Esc cancels. Copy mode is modal and vi-keyed
(h/j/k/l/w/b/e/0/$/g/G, Ctrl+U/D/F/B paging, `v`/`V` select, `y`/Enter yank,
`q`/Esc exit).

Key routing: one `NSEvent.addLocalMonitorForEvents(.keyDown)` in
`KeyInterceptor` (App) runs before any view, translates the event to a
`KeyChord`, and asks `KeyBindingEngine` (`ZettyCore/Keybindings/`, pure +
unit-tested) for a resolution — passthrough, or consume + `BindingCommand`
dispatched into `PaneActions`/`TerminalViewController`/`CopyModeController`.
Guards: events outside the main window, active IME composition, and
text-editing first responders (palette, rename, settings) always pass
through. Status bar shows `PREFIX`/`COPY`/`ZOOM` chips.

Copy mode's keyboard cursor **is a Ghostty selection**: `CopyModeController`
synthesizes in-process mouse press/drag/release into `AppTerminalView` at
computed cell centers (`TerminalViewState.surfaceSize` supplies cell pixel
metrics), so Ghostty renders the highlight natively. Scrolling/copy/paste use
`performBindingAction` (`scroll_page_up`, `scroll_page_fractional:±0.5`,
`scroll_to_top/bottom`, `copy_to_clipboard`, `paste_from_clipboard`). Word
motions scan viewport lines from zmx capture (preserved sessions); without
one they fall back to coarse 8-column jumps. Known limits: panes running
mouse-capturing TUIs may swallow the synthetic clicks; wrapped lines make
zmx-derived rows approximate. Pure cursor math lives in `CopyModeCursor`.

Config: `prefix = <chord>` plus repeated `bind = <chord> <command>` /
`copy-bind = <chord> <command>` lines (additive over the tmux-canonical
defaults in `BindingCommand.default*Table`; no unbind). Chords are
case-sensitive for characters (`G` = shift+g), case-insensitive for modifier
words/named keys; bad lines are skipped and collected in
`KeyBindingConfiguration.issues`. Accepted lines re-emit through
`AppConfig.rendered()` so runtime persists don't drop them. Reload (⇧⌘,)
rebuilds the tables and exits any armed/copy state.

## Tab identity (logos + titles)

Tab pills and sidebar tab rows show **what each pane is running**: a tool logo
(when bundled) plus the title the CLI emits. Precedence (`TabTitle.display`):
manual rename → agent identity (logo, or a `"claude code: <emitted>"` text
prefix when no logo ships) → emitted title (bare shell names are ignored) →
pwd basename → positional.

- **Identity comes from a foreground-process probe**, not hooks: every 3s
  (skipped while the app is inactive) one `zmx list` maps sessions→pids and one
  `ps -axo pid,pgid,stat,tty,command` snapshot finds each session TTY's
  foreground process-group leader (`ForegroundProcess`, pure/tested).
  Interpreter-run CLIs resolve to the script (`python3 …/hermes` → `hermes`);
  a bare interpreter REPL keeps its own name. Requires zmx sessions; without
  them identity falls back to hook-detected agent kind.
- **Logos** live in `App/Resources/AgentLogos/agent-<command>.svg` — monochrome
  SVGs from simple-icons (CC0) / lobe-icons (MIT), loaded as template images
  and tinted to match the row's text (`AgentIcons`). Agents also have glyph
  fallbacks; unknown tools just show their emitted title. Add a tool by
  dropping in `agent-<foreground-command>.svg`.
- **Tuist gotcha:** after changing files under `App/Resources/`, `tuist
  generate` can fail with a bogus `Manifest not found at …/AgentLogos` *and
  delete the xcodeproj* (a later build then silently reuses a stale app). Run
  `mise exec -- tuist clean` first, then generate.

## Control CLI (`zetty`)

The app hosts a Unix control socket (`~/.zetty/zetty.sock`, 0600,
line-JSON — `ControlWire` in `ZettyCore/CLI/`) and the `zetty` CLI drives
it. **The app binary doubles as the CLI** when invoked with a recognized
command (`main.swift` branches before AppKit starts); Settings (⌘,) →
Command Line installs a symlink at `~/.local/bin/zetty`. A standalone
executable also builds via `swift build` (`.build/debug/zetty`). All CLI
logic is shared in `ControlCLI` (ZettyCore, pure Foundation).

Commands (see `zetty --help` for full grammar and agent notes):
- `status [--json]` — projects → tabs → panes: 8-hex pane ids, emitted
  titles, cwd, probed tool, agent status, focused pane.
- `send [--pane <id> | --cwd <path>] [--key <name>]… [--enter] [text…]` —
  inject text/keys into a pane's pty (tmux-style key names incl. C-a…C-z).
- `capture [--pane|--cwd] [--lines <n>]` — a pane's recent output via its
  preserved zmx session (`zmx history`).
- `new-tab [--project <name>] [--focus]` / `split [--pane|--cwd]
  [--horizontal] [--focus]` / `break [--pane|--cwd] [--focus]` — create a
  tab / split a pane / break a pane into a new adjacent tab, in the
  BACKGROUND by default (active project + keyboard focus stay put, so an
  agent can reshape the workspace mid-type); `--focus` switches to the
  result. All print the new pane's bare id for command substitution.
- `add-project <path> [--name <name>]` — add a directory as a project
  (name defaults to the directory name) and make it active; the CLI
  resolves relative paths against its own cwd, and the path must be an
  existing directory not already used by a project. Prints the new
  project's first pane id.
- `remove-project <name>` — remove a project (case-insensitive), closing
  its tabs/panes and ending their zmx sessions; no confirmation dialog,
  and the last remaining project can't be removed.
- `scratch [--focus]` — open a project-less, ephemeral scratch terminal
  (rooted at home, plain shell, never persisted) in the Scratch section, in
  the BACKGROUND by default; `--focus` switches to it. Prints the new pane
  id. `scratch-clear` closes and clears every scratch terminal at once.
- `focus (--pane|--cwd)` · `close (--pane|--cwd) [--tab]` · `reload` ·
  `quit [--kill-sessions]` (no dialog; the flag kills every preserved
  session first — full shutdown).

Errors go to stderr with exit 0/1/2; pane targets resolve by unique id
prefix, unique cwd, or default to the focused pane. Server handlers run on
the main thread (`ControlSocketServer` → `AppDelegate.startControlSocket` →
`TerminalViewController` snapshot/send/split/close/capture).

## AI agent detection

Zetty surfaces running AI agents as **status dots** in the sidebar (per-tab
dots + a per-project roll-up on the diamond): **green = running, yellow =
needs-attention, dim = idle**. The engine is pure/tested in `ZettyCore`
(`AgentRegistry`, `AgentStateMachine`, `AgentDetector`, `AgentEvent`).
Hooks drive the **status dots only** — tab names/logos come from the
foreground-process probe (see "Tab identity" above). At startup the existing
event log replays once (`AgentEventReplay`: last event per cwd+agent, `ended`
drops) so dots recover for agents already running inside preserved sessions.

**Needs-attention notifications** (config-gated, Settings ⌘, → Agents):
`notify-sound` plays a sound; `notify-badge` badges the Dock icon with the
attention-pane count (auto-clears when the agent resumes); `notify-system`
posts a macOS notification while Zetty is in the background — clicking it
focuses the pane. Fired on the *transition into* needsAttention; the startup
replay never notifies (stale state).

Detection is **hook-driven** — libghostty exposes no PTY fd / child PID, so
harness hooks *ping* Zetty:

1. **Settings (⌘,) → Agent Status Hooks** — a toggle per harness installs a
   shared hook helper (`~/.zetty/hooks/zetty-hook.py`) and registers it in the
   harness config (toggle off to uninstall).
2. On a lifecycle event the harness runs the helper, which appends
   `{cwd, agent, event}` to `~/.zetty/agent-events.jsonl`.
3. `AgentEventWatcher` tails that file; `TerminalViewController` correlates each
   event to panes **by working directory** and drives the dots.

Per-harness install (`HookInstaller` + the pure `*HookConfig` transforms):
- **Claude** — additive hooks in `~/.claude/settings.json` (UserPromptSubmit→running,
  Notification→needsAttention, Stop→idle, SessionEnd→ended).
- **Codex** — chains the single `~/.codex/config.toml` `notify` (emits then execs
  your original; uninstall restores it). Only turn-ended fires → idle/presence.
- **Hermes** — `hooks:` block in `~/.hermes/config.yaml` (pre_approval_request→
  needsAttention, pre_llm_call→running, post_llm_call→idle, session start/end). If
  a `hooks:` block already exists, install shows a snippet to merge by hand.

Notes: restart the agent after installing; correlation is by `cwd`, so two panes
in the same directory both light up (exact per-pane routing needs a per-surface
id libghostty doesn't expose).

## Conventions

- Follow existing file patterns; keep files focused. `ZettyCore` stays pure
  (no AppKit import).
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
- **Keep `CLAUDE.md` and `AGENTS.md` byte-identical.** They share one canonical
  content; any edit to one must be replicated to the other in the same commit.
- **Every release ships human-written notes.** When cutting a release, add a
  note to the GitHub release body summarizing the updates and new features it
  introduces — a short, user-facing "What's new" list, not just the
  auto-generated "Full Changelog" link. Group by feature/fix and phrase it for
  users, mirroring the same changes documented in `README.md`.
