# AGENTS.md — quertty

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
xcodebuild -project quertty.xcodeproj -scheme quertty -destination 'platform=macOS' build
```

Tests: `mise exec -- tuist test` (or the `QuerttyGhosttyTests` / `Testing` schemes).

## Design system  ← read before any UI work

**All UI styling follows [`DESIGN.md`](DESIGN.md)**, translated from the Claude
Design handoff `quertty.dc.html`. The tokens live in
[`App/Sources/App/Theme.swift`](App/Sources/App/Theme.swift) (`QTheme`).

Non-negotiable rules (full list in DESIGN.md):

1. **Never hardcode a color.** Read from `QTheme.current.<token>Color`. Need a
   new color? Add a token to `QTheme` — never inline hex or a system color.
2. **Fonts follow content:** terminal-adjacent UI uses `QTheme.monoFont`; prose
   and standard controls use the system font.
3. **Accent = focus/active/brand only, and it glows.** Fills use the `bg3` surface.
4. **Respect the surface ramp:** `bg0` chrome · `bg1` base/panes/terminal · `bg2`
   elevated inputs · `bg3` chips/selection.
5. **The terminal tracks the scheme** via `QTheme.current.terminalTheme()`,
   applied through `SurfaceRegistry.terminalTheme` — set it nowhere else.
6. **Schemes are all-or-nothing:** a new `QColorScheme` fills every token.

When adding UI, match the component anatomy in DESIGN.md (radii, bar heights,
status dots, accent top-bar on the active tab, etc.).

## Conventions

- Follow existing file patterns; keep files focused. `QuerttyCore` stays pure
  (no AppKit import).
- Do not commit debug `NSLog`/`print` statements.
- Never commit or push without being asked; never add `Co-Authored-By` or a
  session link to commit messages.
