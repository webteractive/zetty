# Zetty Design System

The visual language for Zetty — tokens, schemes, typography, and component
anatomy.

- **Code source of truth:** [`App/Sources/App/Theme.swift`](App/Sources/App/Theme.swift) (`ZTheme`)
- **Origin:** a Claude Design handoff (`Zetty.dc.html`, referenced by the
  `palette(for:)` comment in `Theme.swift`). The file is not in the repo and is
  no longer authoritative — the code is.

Zetty is a native **AppKit** app, so this is a *visual* spec: tokens,
typography, spacing, and component anatomy are expressed through AppKit
styling, not HTML. `ZTheme` is the single place those tokens live in code; every
view reads colors and fonts from it.

> **Exact point values rot.** Where this file gives a number, treat it as the
> intended proportion and `Theme.swift` / the view as authoritative. Where the
> two disagree, the code wins and this file is the bug.

> **Contributor rules and configuration behavior live in
> [`CLAUDE.md`](CLAUDE.md) / [`AGENTS.md`](AGENTS.md)**, not here — this file is
> the visual reference only.

---

## Design language

Dark-first, terminal-native, low-chroma surfaces with a single luminous accent.
Depth is expressed through a 4-step surface ramp (`bg0`→`bg3`) plus hairline
borders — never drop shadows on chrome. The **accent** is reserved for focus,
selection, and brand; it always appears with a soft glow, never as a heavy fill.

---

## Color tokens

Values below are the **Midnight** (default dark) scheme. Every scheme defines
the same token set plus an `isDark` flag — see [Schemes](#schemes).

| Token   | Hex       | Role |
|---------|-----------|------|
| `acc`   | `#5eead4` | Accent — focus / active / brand (always glows) |
| `bg0`   | `#09090c` | Deepest surface — sidebar, tab bar, status bar |
| `bg1`   | `#0b0b0f` | Base surface — window, main area, terminal, panes |
| `bg2`   | `#131319` | Elevated — search fields, hover |
| `bg3`   | `#1a1a22` | Highest — pinned rows, kbd chips, selection fill |
| `bord`  | `#1f1f27` | Hairline borders / dividers |
| `fg`    | `#e6e6ea` | Primary text |
| `fg2`   | `#a7a7b2` | Secondary text |
| `fg3`   | `#6a6a75` | Tertiary / dim text, idle status |
| `green` | `#7ee787` | Running / ok |
| `blue`  | `#7c9cff` | Paths / links |
| `purple`| `#d2a8ff` | Git / branch |
| `yellow`| `#e3b341` | Attention / caution |
| `red`   | `#ff7b72` | Error |
| `tfg`   | `#c9d1d9` | Terminal foreground |
| `tdim`  | `#6e7681` | Terminal dim / prompt punctuation |

### Semantic status colors

- **green** — running / healthy
- **yellow** — needs attention / caution (agent attention, clone warning banner)
- **red** — error
- **purple** — git / branch
- **accent** — focused / active pane, selected tab
- **fg3** — idle / inactive

Semantic colors carry meaning; don't repurpose them for decoration.

### Project identity palette

Separate from the accent and the semantic colors, so a project's color can
never be confused with a status. Eight curated hues, each carrying a
dark/light pair that resolves against the current appearance
(`ZTheme.projectPalette` / `projectColor(id:)`). Ids are stored in project
settings; an unknown id degrades to "no color", never an error.

`sky` · `teal` · `moss` · `sand` · `orange` · `pink` · `mauve` · `steel`

---

## Schemes

**20 schemes ship in `ZColorScheme`** — 10 dark, 10 light — selected
independently per appearance axis (`theme-dark` / `theme-light`). **Midnight**
is the default dark scheme and **Daylight** the default light one. Switching
sets `ZTheme.scheme`, which repoints `ZTheme.current` and, for the terminal,
`ZTheme.current.terminalTheme()`.

A new scheme is all-or-nothing: it must fill every token plus `isDark`.

### Dark

| Scheme    | Lineage           | Accent    | Base `bg1` |
|-----------|-------------------|-----------|------------|
| Midnight  | custom            | `#5eead4` | `#0b0b0f`  |
| Nocturne  | Dracula           | `#bd93f9` | `#282a36`  |
| Frost     | Nord              | `#88c0d0` | `#2e3440`  |
| Twilight  | Tokyo Night       | `#7aa2f7` | `#1a1b26`  |
| Ember     | Gruvbox           | `#fabd2f` | `#282828`  |
| Velvet    | Catppuccin Mocha  | `#cba6f7` | `#1e1e2e`  |
| Eclipse   | One Dark          | `#61afef` | `#282c34`  |
| Rosewood  | Rosé Pine         | `#ebbcba` | `#191724`  |
| Neon      | Monokai Pro       | `#ffd866` | `#2d2a2e`  |
| Ukiyo     | Kanagawa          | `#7e9cd8` | `#1f1f28`  |

### Light

| Scheme    | Lineage             | Accent    | Base `bg1` |
|-----------|---------------------|-----------|------------|
| Daylight  | neutral light       | `#0d9488` | `#ffffff`  |
| Paper     | Solarized Light     | `#268bd2` | `#fdf6e3`  |
| Glacier   | Nord light          | `#5e81ac` | `#eceff4`  |
| Dawn      | Rosé Pine Dawn      | `#d7827e` | `#faf4ed`  |
| Latte     | Catppuccin Latte    | `#8839ef` | `#eff1f5`  |
| Porcelain | GitHub light        | `#0969da` | `#ffffff`  |
| Harvest   | Gruvbox light       | `#d65d0e` | `#fbf1c7`  |
| Citrus    | Ayu light           | `#e6650f` | `#fcfcfc`  |
| Daybreak  | Tokyo Night Day     | `#2e7de9` | `#e1e2e7`  |
| Sakura    | cherry blossom      | `#c94f7c` | `#fff7fa`  |

**Daylight** pairs a white terminal/panes surface (`bg1`) with gray chrome
(`bg0` `#ececed`) and a brand-teal accent that reads on white.

---

## Typography

Two font roles, and the split is **not** what "terminal-native" would suggest:

- **`ZTheme.monoFont(size:weight:)`** — JetBrains Mono, falling back to the
  system monospaced face when it isn't installed. Used by **the terminal and
  the status bar only.** It follows the user's configured terminal
  `font-family` / `font-size`.
- **`ZTheme.chromeFont(size:weight:)`** — the system (proportional) font. Used
  by **everything else**: tab bar, sidebar, command palette, dialogs, sheets,
  chips. Deliberately decoupled from the terminal font settings and at a fixed
  point size, so changing your terminal font never reflows the app chrome.

Representative sizes: tab label 12.5 (semibold active / medium inactive),
sidebar rows 13, status bar 10–11 mono. `Theme.swift` and the individual views
are authoritative.

---

## Spacing & radius

- **Surface ramp:** `bg0` (chrome) → `bg1` (base) → `bg2` (elevated) → `bg3` (chips/selection).
  Don't invent intermediate greys.
- **Radii:** window & modals/overlays 14 · sidebar rows 12 · status-bar pills 10 ·
  palette rows 9 · panes 8 · chips & status dots 3–7.
- **Grid:** the terminal grid uses 8pt padding, with 8pt gaps between panes.
- **Bars (heights in pt):** tab bar 28 · status bar 30 · pane gutter strip 24 ·
  clone warning banner 26.
- **Sidebar:** 244 default, user-resizable 180–420 (`SidebarMetrics`).

---

## Component anatomy

- **Window** — `bg1`, 14pt radius, `bord` border; appearance is pinned to the
  effective scheme axis so native chrome (menus, scrollers, titlebar) tracks it.
- **Sidebar** (`bg0`) — filter field (`bg2`); a **Home** row pinned to the very
  top with no section header, no pin button, and no tab children; then
  uppercase section headers with counts — `Pinned`, `Projects`, `Scratch`, and a
  collapsible `Hibernating` sorted by name. Project rows (12pt radius) carry an
  accent left-bar + glow when active, a diamond glyph (or a custom SF Symbol /
  emoji), an accent star when pinned, and a per-project roll-up status dot.
  Expandable projects reveal tab children with their own status dots. **Clone
  rows** nest directly under their source behind a fork glyph; a clone still
  being copied appears as a non-interactive "Cloning…" spinner row. Footer:
  **Add project** + settings.
- **Tab bar** (`bg0`, 28pt) — pills with top-only rounded corners; the active
  pill fills `bg1` and shows a 2pt accent top-bar + glow plus an accent status
  dot, inactive pills are clear with an `fg3` dot. Each pill shows the tool's
  bundled logo (tinted to match the row's text) beside the title, then × close
  (hidden on a lone tab), then `+` and the split buttons. Pills re-render **in
  place** when only content changed — see the chrome-refresh rules in CLAUDE.md.
- **Pane** — `bg1`, 8pt radius, **borderless**. Focus is shown by an accent
  status dot in the 24pt top gutter strip (dim `fg3` when unfocused), which
  also carries click targets for split vertically / split horizontally and, in a
  multi-pane tab, break-into-tab and close. Right-clicking the strip opens the
  same actions as a menu. *(A pane header with name/subtitle and a `RUNNING`
  badge appeared in the original handoff and is still unbuilt.)*
- **Clone warning banner** (26pt) — a persistent yellow-accent caution strip
  below the tab bar whenever the active project is a clone, reminding that the
  copy is disposable. It becomes the content's top guide, so it sits above both
  the terminal and the hibernation placeholder.
- **Status bar** (`bg0`, 30pt, mono) — tracks the focused pane: git branch
  (purple) with ahead/behind/changes, working directory, shell, and libghostty
  version, plus pills for `Open ▾` (opens the focused pane's directory),
  appearance and scheme switchers, an "Update available" pill when one is
  waiting, and mode chips — `PREFIX`, `COPY`, `ZOOM`, `BROADCAST` (yellow).
- **Hibernation placeholder** — shown in the content area when the active
  project is dormant: a `moon.zzz` glyph, "<project> is hibernated", a note
  that its sessions and processes were freed with the layout kept, and a
  **Wake Project** button.
- **Command palette** (⌘K) — centered modal over a scrim, `bg2`, 14pt radius;
  search input, rows (9pt radius) with a glyph chip + label + shortcut.
- **File viewer overlay** — a transient read-only panel (14pt radius) over the
  content area: header with the file name and a ✕, the syntax-highlighted body
  in a plain `NSTextView`/`NSScrollView`, and a footer with `Open in ▾`. The
  referenced line is marked with `bg3`. See CLAUDE.md for why this must **not**
  be rebuilt on a hand-rolled TextKit stack.
- **Sheets** — Project Settings, the agent chooser, the clone sheet, and the
  file copy-back modal are `NSWindow` panels styled from the same tokens.

### Reflexes

1. Never hardcode a color — read `ZTheme.current.<token>Color`, or add a token.
2. Accent means focus / active / brand, and it glows. Selection fills use
   `bg3`, never a saturated accent block.
3. Panes are borderless; focus is the accent dot, not a border.
4. Chrome depth is borders + surfaces, never shadows.
5. A scheme change must invalidate the view-layer render caches — the inputs
   are equal and only the colors differ, so an unchanged-input no-op would
   freeze that widget in the old palette.
