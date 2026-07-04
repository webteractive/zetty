# Design: tmux-style prefix keybindings + copy mode

**Date:** 2026-07-03 · **Status:** Implemented (2026-07-04)
**Roadmap:** Phase 2 — "tmux-style keybindings + copy mode"

## Summary

A prefix-key ("doorbell") layer for controlling Zetty from the keyboard —
`Ctrl+B` then a letter drives splits, pane focus, tabs, zoom, and a vi-style
copy mode with full keyboard cursor/selection over scrollback. Bindings are
fully remappable from `~/.config/zetty/config`. Decision logic lives in
`ZettyCore` (pure, unit-tested); AppKit only translates `NSEvent`s and executes
commands.

## Decisions (settled with Glen)

| Question | Decision |
|---|---|
| Prefix key | `Ctrl+B` (tmux default), configurable |
| v1 action groups | Panes (split/nav/close/zoom) · Tabs (create/switch/rename) · Copy mode + paste. No resize mode (⌘⌥-arrows already exist). |
| Copy mode depth | **Full tmux parity now** — keyboard cursor, vi motions, `v`/`V` selection. Spike-first because the selection mechanism is unproven. |
| Configurability | **Fully remappable** — `prefix =`, repeated `bind =` / `copy-bind =` lines |
| Approach | **A** — central key router + Ghostty-native selection for copy mode (C = Zetty-drawn overlay held as copy-mode-only fallback) |

## Architecture

```
keyDown ──▶ NSEvent local monitor (App layer, one per app)
                │  normalize
                ▼
            KeyChord ──▶ KeyBindingEngine (ZettyCore, pure state machine)
                              │ mode: normal | prefixArmed | copyMode
                              ▼
                 .passthrough        → event continues to ghostty surface
                 .consume(command)   → dispatcher (App layer)
                                        ├─ PaneActions (split/focus/close/zoom)
                                        ├─ tab actions (new/cycle/jump/rename)
                                        └─ CopyModeController
```

- The monitor is registered once (AppDelegate) with
  `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` — it runs before any
  view, so prefix keys work regardless of whether a terminal pane or chrome has
  focus. Returning `nil` swallows the event.
- Existing ⌘ menu shortcuts are untouched; this layer is additive.

### Components

1. **`ZettyCore/Keybindings/KeyChord.swift`** — AppKit-independent key
   representation (base key + modifier set). Parses/serializes the config chord
   syntax (`ctrl+b`, `shift+cmd+x`, bare letters, symbols like `%` and `"`).
2. **`ZettyCore/Keybindings/BindingCommand.swift`** — enum of every dispatchable
   command (pane ops, tab ops, copy-mode ops, `sendPrefixLiteral`,
   `enterCopyMode`, `paste`, …), with the config-name mapping
   (`split-vertical`, `focus-left`, `copy-mode`, …).
3. **`ZettyCore/Keybindings/KeyBindingEngine.swift`** — the state machine.
   Input: `(KeyChord, context)` → output: `.passthrough` / `.consume(command)` /
   `.consumeNoop` (e.g. unbound key while armed: flash + disarm). Holds the
   prefix chord and two tables (prefix table, copy-mode table). No AppKit.
4. **`AppConfig` additions (ZettyCore)** — reserved keys `prefix`, `bind`,
   `copy-bind` (repeated lines allowed). Compiled-in tmux-canonical defaults;
   user lines override per-chord (additive; no `unbind` in v1). Invalid chord
   or unknown command → config warning, line ignored. `bind`/`copy-bind`/`prefix`
   are not ghostty directives (ghostty's own `keybind` keeps forwarding
   verbatim, no collision).
5. **`App/…/KeyInterceptor.swift`** — the monitor + NSEvent→KeyChord
   normalization + dispatch. Skips interception while IME composition is active
   (marked text) so input methods are never broken.
6. **`App/…/CopyModeController.swift`** — owns a copy-mode session for the
   focused pane (virtual cursor, anchor, char/line selection kind). Translates
   motions into synthetic mouse events + `performBindingAction` calls; reads
   viewport text for word/line targets; `y` → `readSelection()` → pasteboard.
7. **Status feedback** — status bar chips: `PREFIX` while armed, `COPY` during
   copy mode. `ZTheme` tokens + mono font per design rules; accent = active
   mode. No pane borders (rule 5).
8. **Pane zoom (new)** — transient display override in the layout tree: render
   only the focused pane in the tab, `z` toggles back. Not persisted to
   `workspace.json`. Pure layout logic in ZettyCore.
9. **Tab rename (new)** — `,` opens an inline title editor in the tab bar. A
   user-set title is an override that persists in `workspace.json` and wins over
   CLI-emitted titles (clearing it restores emitted titles).

## Default bindings (tmux canon)

**Prefix table** (after `Ctrl+B`; one-shot — executes and disarms):

| Key | Command | Key | Command |
|---|---|---|---|
| `%` | split vertical (side-by-side) | `c` | new tab |
| `"` | split horizontal (stacked) | `n` / `p` | next / prev tab |
| `←↑↓→`, `h j k l` | focus pane in direction | `1`–`9` | jump to tab N |
| `o` | cycle panes | `,` | rename tab |
| `x` | close pane (busy guard as today) | `[` | enter copy mode |
| `z` | zoom toggle | `]` | paste |
| `Ctrl+B` | send literal Ctrl+B | `Esc` | cancel |

Unbound key while armed: flash the `PREFIX` chip, disarm, swallow the key.

**Copy-mode table** (sticky until exit):

| Key | Action | Key | Action |
|---|---|---|---|
| `h j k l`, arrows | move cursor | `v` | begin char selection |
| `w` / `b` / `e` | word motions | `V` | line selection |
| `0` / `$` | line start / end | `y`, Enter | copy + exit |
| `g` / `G` | scrollback top / bottom | `Esc`, `q` | exit |
| `Ctrl+U` / `Ctrl+D` | half page up / down | | |
| `Ctrl+B` / `Ctrl+F` | page up / down | | |

The tables are modal: in copy mode `Ctrl+B` resolves through the copy-mode
table (page up, as in tmux's vi mode), not as the prefix — the engine's mode
decides which table applies.

`/` search is **out of scope (v2)** — no search API in libghostty; would need
our own text scan + jump.

## Copy-mode mechanism (the novel part)

The keyboard cursor **is a 1-cell Ghostty selection**, placed by synthesizing
mouse press/drag/release into the surface at computed cell coordinates. Ghostty
renders the selection highlight natively — Zetty draws nothing. Motions re-place
the 1-cell selection (cursor) or extend from the anchor (`v`/`V` active).
Scrolling/paging uses `performBindingAction("scroll_page_up")` et al.; copy uses
`hasSelection()`/`readSelection()`. Word/line-boundary targets are computed from
the viewport text snapshot; cell↔text-offset math has known CJK/wide-char
imprecision (same limitation as upstream's quicklook anchor) — acceptable in v1.

**Spike (step zero, time-boxed ~half day):** on our pinned libghostty prove
(1) synthetic mouse events can place a selection at an exact cell,
(2) `adjust_selection:*` semantics (does it require an existing selection; how
it behaves at viewport edges), (3) selection survives scroll via binding
actions. **Fallback if the spike fails:** copy mode only switches to Approach C —
a Zetty-drawn overlay over a viewport text snapshot — while the router, prefix
layer, config, zoom, and rename are unaffected.

## Edge cases & error handling

- **IME:** never intercept while composition/marked text is active.
- **Focus loss / pane close / tab switch during copy mode:** exit copy mode.
- **Output during copy mode:** Ghostty holds scroll position while scrolled up;
  selection may shift with viewport churn — accepted for v1.
- **Nested tmux / remote zetty:** `Ctrl+B Ctrl+B` sends the literal prefix.
- **`zetty send` CLI:** unaffected (different input path, no NSEvent).
- **Config reload (⇧⌘,):** rebuilds engine tables live, exits any armed/copy
  state.
- **zmx-preserved panes:** same view path; no special handling.

## Testing

- **ZettyCore unit tests:** chord parsing (valid/invalid/symbols), engine mode
  transitions (arm → command → disarm; literal prefix; cancel; unbound flash),
  config parsing (defaults, per-chord override, repeated lines, bad lines warn),
  copy-mode command mapping, word-motion target math over sample viewport text,
  zoom layout override.
- **Spike artifact:** probe results recorded in the implementation plan.
- **Live verification:** Glen verifies interactive behavior in the installed app
  (screenshots are TCC-blocked for agent sessions).

## Out of scope (v1)

Copy-mode search (`/`), `unbind`, resize mode, rectangle selection, named
buffers/registers, mouse behavior changes.
