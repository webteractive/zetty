# AGENTS.md — Zetty

Guidance for AI agents and contributors working in this repo.

## What this is

quertty is a native macOS (Linux later) GUI **terminal multiplexer** built on
**full libghostty** (via the prebuilt `libghostty-spm` package) with a Swift
AppKit application layer. Work is organized around pinnable **projects**, each
owning **tabs** and nested **split panes**. See [`README.md`](README.md) and the
PRD in `docs/plans/`.

## Layout

- `Sources/QuerttyCore/**` — pure, testable model (no AppKit): `Surface`,
  `SurfaceNode`, `PaneTree`, `TabList`, `WorkspaceModel`, persistence.
- `App/Sources/App/**` — AppKit app: `AppDelegate`, `TerminalViewController`,
  `SidebarView`, `TabBarView`, `SurfaceNodeView`, `PaneActions`, `Theme.swift`.
- `App/Sources/QuerttyGhostty/**` — libghostty bridge: `SurfaceRegistry`, `Ghostty`.

## Build / run

The Xcode project is **Tuist-generated**. Sources are listed explicitly, so
**after adding or removing a file you must regenerate**:

```sh
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```

Tests: `mise exec -- tuist test` (or the `QuerttyGhosttyTests` / `Testing` schemes).

## Design rules  ← read before any UI work

The *visual* spec (tokens, schemes, typography, component anatomy) is in
**[`DESIGN.md`](DESIGN.md)**; tokens live in
[`App/Sources/App/Theme.swift`](App/Sources/App/Theme.swift) (`QTheme`). DESIGN.md
is appearance-only — these enforceable rules (and Configuration, below) live here.
A change that violates one should be corrected before merge:

1. **Never hardcode a color.** Read from `QTheme.current.<token>Color`; add a
   token rather than inlining hex or a system color (`.controlAccentColor`,
   `.separatorColor`, `.windowBackgroundColor`, …).
2. **Fonts follow content:** terminal-adjacent UI (tabs, project tree, status
   bar, kbd chips) uses `QTheme.monoFont`; prose and standard controls use the
   system font.
3. **Accent = focus/active/brand only, and it glows.** Selection/active fills use
   `bg3`, never a saturated accent block.
4. **Respect the surface ramp:** `bg0` chrome (sidebar / tab bar / status bar) ·
   `bg1` base/panes/terminal · `bg2` elevated inputs & hover · `bg3`
   chips/selection. Don't invent intermediate greys.
5. **Panes are borderless;** focus is shown by the accent status dot, not a border.
6. **The terminal tracks the scheme** via `QTheme.current.terminalTheme()`,
   applied through `SurfaceRegistry.terminalTheme` — set it nowhere else. (Pasted
   ghostty directives may override terminal colors; see Configuration.)
7. **Schemes are all-or-nothing:** a new `QColorScheme` fills every token plus
   its `isDark` flag.
8. **Semantic colors carry meaning** (green=ok, yellow=attention, red=error,
   purple=git, `fg3`=idle). Don't repurpose them for decoration.
9. **Chrome depth is borders + surfaces, not shadows;** reserve glow for the
   accent on focused/active elements.

When adding UI, match the component anatomy in DESIGN.md (radii, bar heights,
status dots, accent top-bar on the active tab, etc.).

## Configuration

quertty reads `~/.config/zetty/config` (or `$XDG_CONFIG_HOME/zetty/config`),
seeded with a documented default on first launch. Parsing is pure + unit-tested
in `QuerttyCore` (`AppConfig` / `ConfigStore`); `AppDelegate` resolves + applies it.

- **`appearance = system | dark | light`** — `system` (default) follows macOS
  live (KVO on `NSApp.effectiveAppearance`); `dark`/`light` pin one axis.
- **`theme-dark` / `theme-light`** — the `QColorScheme` for each axis (case-insensitive).
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
  one-shot startup reap kills `zetty-*` sessions (and pre-rename `quertty-*` ones) no restored surface owns
  (crash leftovers), and Settings offers a manual kill too. The
  Settings (⌘,) toggle offers to download the zmx release binary from zmx.sh
  into `~/.quertty/bin` when missing (Homebrew/manual installs are detected
  too); config-only enablement without zmx falls back to plain shells with a
  one-time alert. Pure logic in
  `QuerttyCore` (`SessionPersistence`); process IO in `ZmxRunner`.
  Reattach gotchas handled in the app layer:
  - **`ZMX_SESSION` is stripped** from the attach command (`env -u`) and from
    every zmx subprocess: inherited from a zmx-backed terminal (Supacode, or
    quertty itself), `zmx attach` would *kill* that session instead of
    attaching the target.
  - **Repaint nudge** — zmx replays screen contents but a running TUI paints
    only deltas, so a reattached pane stays half-drawn; ~1s after a pane's
    surface appears it is shrunk ~20pt and restored (SIGWINCH → full repaint).
  - **Title persistence** — zmx never replays the title escape sequence, so
    each surface's last emitted title persists as `Surface.lastTitle` in
    `workspace.json` and seeds the tab name until the program emits a fresh
    one (`SurfaceRegistry.title` returns nil for the empty initial title so
    the fallback engages).

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

The app hosts a Unix control socket (`~/.quertty/quertty.sock` — legacy path
until the repo-layer rename; 0600,
line-JSON — `ControlWire` in `QuerttyCore/CLI/`) and the `zetty` CLI drives
it. **The app binary doubles as the CLI** when invoked with a recognized
command (`main.swift` branches before AppKit starts); Settings (⌘,) →
Command Line installs a symlink at `~/.local/bin/zetty`. A standalone
executable also builds via `swift build` (`.build/debug/quertty`). All CLI
logic is shared in `ControlCLI` (QuerttyCore, pure Foundation).

Commands (see `zetty --help` for full grammar and agent notes):
- `status [--json]` — projects → tabs → panes: 8-hex pane ids, emitted
  titles, cwd, probed tool, agent status, focused pane.
- `send [--pane <id> | --cwd <path>] [--key <name>]… [--enter] [text…]` —
  inject text/keys into a pane's pty (tmux-style key names incl. C-a…C-z).
- `capture [--pane|--cwd] [--lines <n>]` — a pane's recent output via its
  preserved zmx session (`zmx history`).
- `new-tab [--project <name>]` / `split [--pane|--cwd] [--horizontal]` —
  both print the new pane's bare id for command substitution.
- `focus (--pane|--cwd)` · `close (--pane|--cwd) [--tab]` · `reload` ·
  `quit [--kill-sessions]` (no dialog; the flag kills every preserved
  session first — full shutdown).

Errors go to stderr with exit 0/1/2; pane targets resolve by unique id
prefix, unique cwd, or default to the focused pane. Server handlers run on
the main thread (`ControlSocketServer` → `AppDelegate.startControlSocket` →
`TerminalViewController` snapshot/send/split/close/capture).

## AI agent detection

quertty surfaces running AI agents as **status dots** in the sidebar (per-tab
dots + a per-project roll-up on the diamond): **green = running, yellow =
needs-attention, dim = idle**. The engine is pure/tested in `QuerttyCore`
(`AgentRegistry`, `AgentStateMachine`, `AgentDetector`, `AgentEvent`).
Hooks drive the **status dots only** — tab names/logos come from the
foreground-process probe (see "Tab identity" above). At startup the existing
event log replays once (`AgentEventReplay`: last event per cwd+agent, `ended`
drops) so dots recover for agents already running inside preserved sessions.

**Needs-attention notifications** (config-gated, Settings ⌘, → Agents):
`notify-sound` plays a sound; `notify-badge` badges the Dock icon with the
attention-pane count (auto-clears when the agent resumes); `notify-system`
posts a macOS notification while quertty is in the background — clicking it
focuses the pane. Fired on the *transition into* needsAttention; the startup
replay never notifies (stale state).

Detection is **hook-driven** — libghostty exposes no PTY fd / child PID, so
harness hooks *ping* quertty:

1. **Settings (⌘,) → Agent Status Hooks** — a toggle per harness installs a
   shared hook helper (`~/.quertty/hooks/quertty-hook.py`) and registers it in the
   harness config (toggle off to uninstall).
2. On a lifecycle event the harness runs the helper, which appends
   `{cwd, agent, event}` to `~/.quertty/agent-events.jsonl`.
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

- Follow existing file patterns; keep files focused. `QuerttyCore` stays pure
  (no AppKit import).
- Do not commit debug `NSLog`/`print` statements.
- Never commit or push without being asked; never add `Co-Authored-By` or a
  session link to commit messages.
