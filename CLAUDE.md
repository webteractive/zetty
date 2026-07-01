# CLAUDE.md — quertty

Project instructions for Claude Code. See [`AGENTS.md`](AGENTS.md) for the full
contributor guide (layout, build/run, conventions) — the essentials are below.

## What this is

Native macOS (Linux later) GUI **terminal multiplexer** on **full libghostty**
(`libghostty-spm`) with a Swift AppKit layer. Projects → tabs → nested split panes.

## Build / run (Tuist-generated project)

Sources are listed explicitly, so **regenerate after adding/removing a file**:

```sh
mise exec -- tuist generate --no-open
xcodebuild -project quertty.xcodeproj -scheme quertty -destination 'platform=macOS' build
```

Tests: `mise exec -- tuist test`.

## Design system — read before any UI change

All UI styling follows **[`DESIGN.md`](DESIGN.md)** (translated from the Claude
Design handoff `quertty.dc.html`). Tokens live in
[`App/Sources/App/Theme.swift`](App/Sources/App/Theme.swift) (`QTheme`).

Non-negotiable (full list in DESIGN.md):

1. **Never hardcode a color** — read `QTheme.current.<token>Color`; add a token
   rather than inlining hex or a system color.
2. **Fonts follow content:** terminal-adjacent UI uses `QTheme.monoFont`; prose
   uses the system font.
3. **Accent = focus/active/brand only, and it glows;** fills use `bg3`.
4. **Surface ramp:** `bg0` chrome · `bg1` base/panes/terminal · `bg2` elevated ·
   `bg3` chips/selection.
5. **The terminal tracks the scheme** via `QTheme.current.terminalTheme()`,
   applied through `SurfaceRegistry.terminalTheme` — nowhere else.
6. **Schemes are all-or-nothing** — a new `QColorScheme` fills every token.

## Guardrails

- Keep `QuerttyCore` pure (no AppKit). Don't commit debug `NSLog`/`print`.
- Never commit/push without being asked; no `Co-Authored-By` or session links in
  commit messages.
