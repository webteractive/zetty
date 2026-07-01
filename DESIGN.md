# quertty Design System

The visual language for quertty, translated from the Claude Design handoff.

- **Source handoff:** `quertty.dc.html`
- **Project:** `https://claude.ai/design/p/def4312f-4b6c-41d2-ae44-98d0d130c35b`
- **Code source of truth:** [`App/Sources/App/Theme.swift`](App/Sources/App/Theme.swift) (`QTheme`)

quertty is a native **AppKit** app, so the handoff is a *visual* spec: its
tokens, typography, spacing, and component anatomy are translated into AppKit
styling — we do not render HTML. `QTheme` is the single place those tokens live
in code; every view reads colors and fonts from it.

---

## Design language

Dark-first, terminal-native, low-chroma surfaces with a single luminous accent.
Depth is expressed through a 4-step surface ramp (`bg0`→`bg3`) plus hairline
borders — never drop shadows on chrome. The **accent** is reserved for focus,
selection, and brand; it always appears with a soft glow, never as a heavy fill.
Everything terminal-adjacent (tabs, the project tree, the status bar, kbd chips)
is set in **JetBrains Mono**; only prose and system chrome use the system font.

---

## Color tokens

Values below are the **Midnight** (default) scheme. Every scheme defines the
same token set — see [Schemes](#schemes).

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
| `yellow`| `#e3b341` | Attention / deploy |
| `red`   | `#ff7b72` | Error |
| `tfg`   | `#c9d1d9` | Terminal foreground |
| `tdim`  | `#6e7681` | Terminal dim / prompt punctuation |

### Semantic status colors

- **green** — running / healthy
- **yellow** — needs attention / deploying
- **red** — error
- **purple** — git / branch
- **accent** — focused / active pane, selected tab
- **fg3** — idle / inactive

---

## Schemes

Six schemes ship in `QColorScheme`; **Midnight** is the default. Switching sets
`QTheme.scheme`, which repoints `QTheme.current` and (for the terminal)
`QTheme.current.terminalTheme()`.

| Scheme     | Lineage           | Accent    | Base bg   | Dark? |
|------------|-------------------|-----------|-----------|-------|
| Midnight   | custom            | `#5eead4` | `#0b0b0f` | yes |
| Nocturne   | Dracula           | `#bd93f9` | `#282a36` | yes |
| Frost      | Nord              | `#88c0d0` | `#2e3440` | yes |
| Twilight   | Tokyo Night       | `#7aa2f7` | `#1a1b26` | yes |
| Ember      | Gruvbox           | `#fabd2f` | `#282828` | yes |
| Daylight   | neutral light     | `#0d9488` | `#ffffff` | no  |
| Paper      | Solarized Light   | `#268bd2` | `#fdf6e3` | no  |

**Daylight** is the default light scheme: white terminal/panes (`bg1`), gray
chrome/sidebar (`bg0` `#ececed`), and a brand-teal accent that reads on white.

---

## Typography

- **Mono:** JetBrains Mono (`QTheme.monoFont(size:weight:)`), falling back to the
  system monospaced face when JetBrains Mono is not installed. Weights 400–700.
- **UI/prose:** system font (`NSFont.systemFont`).
- **Terminal:** JetBrains Mono via `withFontFamily("JetBrains Mono")`.

Key sizes: tab label 12.5 (semibold active / medium inactive), sidebar tree 12
mono, project name 13 system-medium, section headers 10.5 mono uppercase
(letter-spacing ~1.4), pane header 11.5 mono, status bar 11 mono.

---

## Spacing & radius

- **Surface ramp:** `bg0` (chrome) → `bg1` (base) → `bg2` (elevated) → `bg3` (chips/selection).
- **Radii:** window 14 · panes/modals 10–14 · pills/controls 8–9 · kbd chips & dots 5–7.
- **Grid:** terminal grid uses 8pt padding and 8pt gaps between panes.
- **Bars:** titlebar 46 · tab bar 42 · pane header 30 · status bar 28 (heights in pt).

---

## Component anatomy

- **Window** — `bg1`, 14pt radius, `bord` border; dark appearance so native
  chrome (menus, scrollers, titlebar) tracks the scheme.
- **Sidebar** (`bg0`, ~264pt) — filter field (`bg2`), uppercase section headers
  (`Pinned`, `Projects`) with counts, project rows (34pt, 8pt radius) with an
  accent left-bar + glow when active, a diamond project glyph, and an accent
  star for pinned. Expandable projects reveal tab children with pulse-dot status.
  Footer: **Add project** + settings.
- **Tab bar** (`bg0`, 42pt) — tabs with top-only rounded corners; the active tab
  fills `bg1`, shows a 2pt accent top-bar + glow and an accent status dot;
  inactive tabs are clear with an `fg3` dot. Two-line mono label (name + meta),
  × close (hidden on a lone tab), then `+` and split-right / split-down buttons.
- **Pane** — `bg1`, rounded; **borderless**. Focus is shown by an accent status
  dot in the pane's top-left gutter (dim `fg3` when unfocused). *(The handoff also
  shows a pane header with name/subtitle + a `RUNNING` badge — not yet built.)*
- **Status bar** (`bg0`) — git branch (purple) + ahead/behind/changes, cwd
  (centered), then appearance + scheme switchers, shell, libghostty version.
- **Command palette** (⌘K) — centered modal over a scrim, `bg2`, 14pt radius;
  mono search input, rows with a glyph chip + label + shortcut.

> **Contributor rules and configuration behavior live in
> [`CLAUDE.md`](CLAUDE.md) / [`AGENTS.md`](AGENTS.md)**, not here — this file is
> the visual reference only.
