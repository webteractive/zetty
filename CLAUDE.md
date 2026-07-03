# CLAUDE.md — Zetty

Project instructions for Claude Code. See [`AGENTS.md`](AGENTS.md) for the full
contributor guide (layout, build/run, conventions) — the essentials are below.

## What this is

**Zetty** (formerly quertty). Native macOS (Linux later) GUI **terminal multiplexer** on **full libghostty**
(`libghostty-spm`) with a Swift AppKit layer. Projects → tabs → nested split panes.

## Build / run (Tuist-generated project)

Sources are listed explicitly, so **regenerate after adding/removing a file**:

```sh
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```

Tests: `mise exec -- tuist test`.

**Gotcha:** after changing files under `App/Resources/`, generate can fail with
a bogus `Manifest not found at …/AgentLogos` **and delete the xcodeproj** — a
later `open` of DerivedData then silently runs a stale build. Run
`mise exec -- tuist clean` first, and confirm generate/build actually succeeded
before judging results.

## Design rules — read before any UI change

The *visual* spec (tokens, schemes, typography, component anatomy) lives in
**[`DESIGN.md`](DESIGN.md)**; tokens are in
[`App/Sources/App/Theme.swift`](App/Sources/App/Theme.swift) (`ZTheme`). These
enforceable rules govern how UI code uses it — a change that violates one should
be corrected before merge:

1. **Never hardcode a color** — read `ZTheme.current.<token>Color`; add a token
   rather than inlining hex or a system color (`.controlAccentColor`,
   `.separatorColor`, `.windowBackgroundColor`, …).
2. **Fonts follow content:** terminal-adjacent UI (tabs, project tree, status
   bar, kbd chips) uses `ZTheme.monoFont`; prose and standard controls use the
   system font.
3. **Accent = focus/active/brand only, and it glows;** selection/active fills use
   `bg3`, never a saturated accent block.
4. **Surface ramp:** `bg0` chrome (sidebar / tab bar / status bar) · `bg1`
   base/panes/terminal · `bg2` elevated inputs & hover · `bg3` chips/selection.
   Don't invent intermediate greys.
5. **Panes are borderless;** focus is shown by the accent status dot, not a border.
6. **The terminal tracks the scheme** via `ZTheme.current.terminalTheme()`,
   applied through `SurfaceRegistry.terminalTheme` — nowhere else. (A user's
   pasted ghostty directives may override terminal colors; see Configuration.)
7. **Schemes are all-or-nothing** — a new `ZColorScheme` fills every token plus
   its `isDark` flag.
8. **Semantic colors carry meaning** (green=ok, yellow=attention, red=error,
   purple=git, `fg3`=idle). Don't repurpose them for decoration.
9. **Chrome depth is borders + surfaces, not shadows;** reserve glow for the
   accent on focused/active elements.

## Configuration

Zetty reads `~/.config/zetty/config` (or `$XDG_CONFIG_HOME/zetty/config`),
seeded with a documented default on first launch. Parsing is pure + unit-tested
in `ZettyCore` (`AppConfig` / `ConfigStore`); `AppDelegate` resolves it.

- **`appearance = system | dark | light`** — `system` (default) follows macOS
  live; `dark`/`light` pin one axis.
- **`theme-dark` / `theme-light`** — the `ZColorScheme` used for each axis.
- **`sidebar-position = left | right`** — which window side the project sidebar
  sits on (also in Settings → Appearance). Collapsed state and the user-dragged
  width persist in `workspace.json`, not here.
- **Every other `key = value` is a ghostty directive**, forwarded verbatim to
  libghostty (via `TerminalConfiguration`) — users can paste an existing ghostty
  config straight in (no prefix; we don't read `~/.config/ghostty/config`).
  Ghostty defines none of the reserved keys, so there's no collision. Comments
  are **full-line only** (`#` at line start) so `#`-prefixed colors survive.
- **Font is uniform:** Settings → Appearance's Font/Font size controls read and
  write the `font-family`/`font-size` **ghostty directives** (no Zetty keys);
  `ZTheme` derives the chrome font from the same directives (`fontFamily` +
  `fontScale`, chrome scale clamped 0.85–1.35), so terminal and chrome change
  together — including when the directives are hand-edited or pasted.
- **Precedence:** scheme theme → pasted ghostty directives (last wins). Pasted
  directives can override terminal colors; chrome stays scheme-driven.
- **Reload:** ⇧⌘, (also App menu + palette) re-reads config and re-applies theme
  + terminal overrides to every live pane; runtime scheme/appearance changes are
  persisted back to the file.
- **`preserve-sessions`** (default false) — panes run inside zmx sessions that
  survive quit/relaunch (quit survives, close kills, startup reaps crash
  orphans). Attach strips `ZMX_SESSION` (inherited from a zmx-backed terminal
  it makes `zmx attach` kill that session); reattached panes get a one-shot
  resize nudge so TUIs repaint. Settings toggle can install zmx; details in
  [`AGENTS.md`](AGENTS.md).
- **Baked-in ghostty defaults** (user directives win): `shell-integration =
  zsh`, `shell-integration-features = ssh-env,ssh-terminfo`.
- **`prefix` / `bind` / `copy-bind`** — the tmux-style prefix-key layer.
  `Ctrl+B` then a key drives panes/tabs (`%` `"` split · h/j/k/l or arrows
  focus · `o` cycle · `x` close · `z` zoom · `c`/`n`/`p`/`1-9` tabs · `,`
  rename · `[` copy mode · `]` paste · prefix-twice sends the literal). Copy
  mode is vi-keyed; its keyboard cursor is a Ghostty-native selection driven
  by synthetic mouse events. Fully remappable (`bind = <chord> <command>`);
  the decision core is pure/tested in `ZettyCore/Keybindings/`; one NSEvent
  local monitor intercepts (never during IME composition or text editing).
  Details in [`AGENTS.md`](AGENTS.md).

## AI agent detection & tab identity

Running agents show as sidebar status dots (green=running, yellow=needs-attention,
dim=idle). Dots are **hook-driven**: **Settings (⌘,) → Agent
Status Hooks** toggles a hook helper (`~/.zetty/hooks/zetty-hook.py`) into each harness
(Claude `settings.json` · Codex chained `notify` · Hermes `config.yaml`), which
appends `{cwd,agent,event}` to `~/.zetty/agent-events.jsonl`; Zetty tails that
(replaying the log once at startup) and correlates to panes by `cwd`.

**Tab names/logos are NOT hook-driven:** a zmx/ps probe resolves each preserved
pane's foreground process (interpreter-aware) and the tab shows its bundled
logo (`App/Resources/AgentLogos/agent-<command>.svg`, template-tinted) plus the
title the CLI emits; last emitted titles persist in `workspace.json` across
relaunches. Engine is pure/tested in `ZettyCore`. Full details in
[`AGENTS.md`](AGENTS.md).

## Control CLI

`zetty` (symlink installed via Settings → Command Line; the app binary
doubles as the CLI) drives the app over `~/.zetty/zetty.sock`:
`status [--json]` · `send` (text + tmux-style keys into any pane) ·
`capture` (pane output) · `new-tab` / `split` (print the new pane id) ·
`remove-project` (closes the project's tabs, no confirmation) ·
`focus` · `close` · `reload` · `quit [--kill-sessions]`. Agent-friendly:
machine-readable output, stderr errors, exit 0/1/2. Protocol + CLI logic
pure in `ZettyCore/CLI/`; details in [`AGENTS.md`](AGENTS.md).

## Guardrails

- Keep `ZettyCore` pure (no AppKit). Don't commit debug `NSLog`/`print`.
- Never commit/push without being asked; no `Co-Authored-By` or session links in
  commit messages.
