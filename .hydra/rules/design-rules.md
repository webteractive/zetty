---
paths:
    - "App/Sources/App/Theme.swift"
    - "DESIGN.md"
    - "App/Sources/App/**/*View.swift"
    - "App/Sources/App/**/*Sheet.swift"
    - "App/Sources/App/**/*Overlay.swift"
    - "App/Sources/App/**/*WindowController.swift"
triggers:
    - "adding or changing any UI: chrome, dialogs, sheets, colors or fonts"
    - "adding or changing a color scheme or theme token"
---

# Design rules (UI)

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

The *visual* spec (tokens, schemes, typography, component anatomy) is in
**[`DESIGN.md`](DESIGN.md)**; tokens live in
[`App/Sources/App/Theme.swift`](App/Sources/App/Theme.swift) (`ZTheme`). DESIGN.md
is appearance-only — these enforceable rules live here (configuration in `configuration.md`).
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
   ghostty directives may override terminal colors; see `configuration.md`.)
7. **Schemes are all-or-nothing:** a new `ZColorScheme` fills every token plus
   its `isDark` flag.
8. **Semantic colors carry meaning** (green=ok, yellow=attention, red=error,
   purple=git, `fg3`=idle). Don't repurpose them for decoration.
9. **Chrome depth is borders + surfaces, not shadows;** reserve glow for the
   accent on focused/active elements.

When adding UI, match the component anatomy in DESIGN.md (radii, bar heights,
status dots, accent top-bar on the active tab, etc.).
