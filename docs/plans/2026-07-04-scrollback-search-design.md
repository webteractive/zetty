# Scrollback Search (Find-in-Buffer) — Design

**Date:** 2026-07-04 · **Status:** Proposed — **more expensive than it looks;
read §"Reality check" first**

A find bar (`⌘F`) to search the terminal buffer, highlight the current match,
and jump between matches with ↵ / ⇧↵. Table-stakes for a terminal — its absence
is what power users notice on day one. But the implementation reality is
non-obvious and materially changes the effort estimate, so this plan leads with
that.

## Reality check — what libghostty gives us (and doesn't)

Investigated against the linked `libghostty-spm` sources and `ghostty.h`:

1. **Native search is unreachable.** The C ABI has
   `GHOSTTY_ACTION_START_SEARCH / END_SEARCH / SEARCH_TOTAL / SEARCH_SELECTED`,
   but they are **core→apprt notifications** with no inbound "feed a needle"
   function, and libghostty-spm drops them in a `default:` case with no delegate
   hook. Native search is **not wired and not callable** without patching the
   package. Treat it as unavailable.
2. **No `set_selection`, no `scroll_to_row`.** You cannot programmatically
   create a highlight or jump the viewport to an arbitrary row. Highlighting is
   Ghostty's *single* native selection, created only by synthesizing mouse
   drags (what copy mode does); scrolling is relative/paged only
   (`scroll_to_top/bottom`, `scroll_page_up/down`, `scroll_page_fractional:±X`).
3. **Text extraction exists in C but isn't public in Swift.**
   `ghostty_surface_read_text(surface, selection, out)` can read any range —
   including full scrollback via `GHOSTTY_POINT_SCREEN` — and there's a working
   template (`InMemoryTerminalSession.readViewportText()`), but it's `internal`
   and only on the in-memory backend, which Zetty's `.exec` panes don't use.
4. **Today's only text source is zmx.** Both `zetty capture` and copy-mode word
   motions read `zmx history <session>`, which **only exists when
   preserve-sessions is on.** There is no ghostty-based text path in Zetty now.

**Consequence:** there are two honest ways to build this, with very different
cost and coverage. This plan does **Phase 1** first (ships value with zero
package changes) and treats **Phase 2** as a separate, evaluated commitment.

## Goals

- `⌘F` opens a find bar attached to the focused pane; type a needle, see match
  count, jump next/prev, `Esc` closes.
- Reuse copy mode's proven mechanism (paged scroll + synthetic-mouse selection)
  to highlight and reveal the current match.
- A `FIND` / match-count chip in the status bar, consistent with
  PREFIX/COPY/ZOOM.

## Non-goals

- Regex / fuzzy search in the first cut (literal substring, case-insensitive
  toggle only).
- Highlighting **all** matches simultaneously — Ghostty allows one native
  selection, so "highlight all" would need a Zetty-drawn overlay on top of the
  terminal (deferred; current match highlight only).
- Cross-pane / workspace-wide search.

## Phase 1 — Viewport + zmx scrollback (no package changes)

Ships the feature for the visible viewport always, and for full scrollback when
`preserve-sessions` is on (which is the intended power-user config anyway).

### Text source

- **Preserved pane:** search `zmx history <session>` — the exact source
  `captureSource(target:)` (`TerminalViewController.swift:1221`) +
  `ZmxRunner.history(...)` (`ZmxRunner.swift:55`) already expose. This gives
  full scrollback text with row offsets.
- **Non-preserved pane:** search only the visible viewport. Since we can't read
  ghostty viewport text without the package patch, Phase 1 either (a) limits
  non-preserved panes to "search what's on screen" by scrolling + visual
  confirmation, or (b) is honestly gated: the find bar shows "scrollback search
  needs preserve-sessions" for non-preserved panes. **Recommendation: (b)** —
  don't ship a half-working silent search. This also creates a natural nudge
  toward preserve-sessions.

### Match navigation + highlight (mirror copy mode)

`CopyModeController` (`App/Sources/App/CopyModeController.swift`) is the
blueprint — it already (a) scrolls via `performBindingAction` and (b) renders a
native highlight by synthesizing `.leftMouseDown → drag → .leftMouseUp` over a
computed cell range (`placeSelection`/`drag`/`send`, `:153/:191/:206`), using
`gridMetrics` (`TerminalGridMetrics`) and flipping y to AppKit coords.

A `SearchController` reuses that machinery:

1. Find match offsets in the text source (pure string search in `ZettyCore`).
2. Map a match's offset → (row, col) range. For zmx text we know line
   structure; the match's absolute row → distance from the viewport bottom.
3. Scroll the match into the viewport — no scroll-to-row, so approximate with
   `scroll_page_fractional` / repeated paging until the target row is on
   screen, then place the selection with copy mode's `placeSelection`/`drag`
   (mouse coords are viewport-relative, so the match **must** be scrolled into
   view before it can be highlighted).
4. ↵ / ⇧↵ advance the current-match index and repeat.

### UI

- **Find bar:** clone `CommandPaletteView`
  (`App/Sources/App/CommandPaletteView.swift`) — a code-built `NSView` with a
  bare `NSTextField`, first-responder grab in `viewDidMoveToWindow`, live filter
  in `controlTextDidChange`, and `control(_:textView:doCommandBy:)` mapping
  `insertNewline`→next, `cancelOperation`→close. Remap ↵=next, ⇧↵=prev.
  Attach it pinned to the **top-trailing of the focused pane's
  `LeafContainerView`** (`SurfaceNodeView.swift:143`, analogous to the existing
  close-gutter inset), not full-bleed like the palette. Held in a
  `private var searchView: SearchBarView?` on the VC, toggled like
  `commandPaletteView` (`:67/:933–960`).
- **Chip:** add `.search` to `KeyMode`
  (`Sources/ZettyCore/Keybindings/KeyBindingEngine.swift:6`) and a
  ` FIND · 3/12 ` chip in `StatusBarView` (mirror `setKeyMode`,
  `StatusBarView.swift:249`). Match count maps naturally onto the (currently
  inert) SEARCH_TOTAL/SEARCH_SELECTED concepts.
- **Binding:** native `⌘F` menu item; optional prefix `bind = / search` via a
  new `BindingCommand.enterSearch`.

### Phase 1 limits (state them in the chip / bar, don't hide them)

- Non-preserved panes: viewport-only or gated (per recommendation (b)).
- Current match highlighted, not all matches.
- TUIs that capture the mouse may swallow the synthetic selection clicks (same
  caveat copy mode documents, `CopyModeController.swift:17`).

## Phase 2 — Native scrollback via a libghostty-spm patch (evaluated separately)

Removes the preserve-sessions dependency and makes search work on every pane
against Ghostty's own buffer. Requires a **small, mechanical fork/patch** of
libghostty-spm:

- Expose `ghostty_surface_read_text` as a public
  `AppTerminalView.readText(selection:) -> String?` (lift
  `InMemoryTerminalSession.readViewportText()`, `:74`, but with
  `GHOSTTY_POINT_SCREEN` top-left→bottom-right to cover scrollback).
- Optionally expose `readSelectionResult()` / `hasSelection()` publicly for
  offset math.

Cost/risk: we consume libghostty-spm as a prebuilt SPM package; patching means
maintaining a fork or upstreaming the wrapper (preferred — these are thin,
generally-useful accessors). **Do not start Phase 2 until Phase 1 is in daily
use** and we've confirmed the preserve-sessions gating is actually annoying.
Native search-mode (the START_SEARCH action path) is explicitly *not* pursued —
higher effort, uncertain, and needs a core keybind action string we haven't
confirmed exists.

## Edge cases

- **No matches:** chip shows ` FIND · 0/0 `; no scroll/highlight; bar stays open.
- **Match spanning a wrapped line / off-screen columns:** highlight the
  on-screen portion; acceptable for v1.
- **Live output while searching:** the buffer moves under you. On each new
  needle/navigation, re-read the source and re-resolve offsets rather than
  caching row numbers across output.
- **Case sensitivity:** default insensitive; a toggle in the bar flips it
  (pure-search parameter).
- **Copy-mode / prefix interaction:** search is its own `KeyMode`; entering it
  from normal mode only, and `Esc` returns to normal. Cannot be active
  simultaneously with copy mode.
- **Empty needle:** no-op, clears the current highlight.

## Testing

`ZettyCoreTests` (pure): the match engine — substring search over a text blob
returning ordered `(offset, length)` and `(row, col)` ranges; case toggle;
zero-match; overlapping/adjacent matches; multi-line text; next/prev index
wrap-around. This is the meaty testable core.

App layer (scroll-into-view, synthetic-mouse highlight, find bar focus/keys) is
manual — GUI capture is TCC-blocked, and this reuses copy mode's already-proven
event synthesis. Manual script (preserve-sessions ON): generate long output,
`⌘F` a term appearing above the fold, confirm it scrolls into view + highlights,
↵ cycles matches with correct count, `Esc` restores. Repeat with
preserve-sessions OFF to confirm the gating message.

## Rollout

1. Commit 1: pure match engine + tests (`ZettyCore`).
2. Commit 2: `SearchController` (scroll + highlight, reusing CopyMode
   machinery) against the zmx text source.
3. Commit 3: find bar UI + `KeyMode.search` + chip + `⌘F` / `enter-search`
   binding + non-preserved gating.
4. *(Phase 2, separate plan + decision)* libghostty-spm `readText` patch →
   native scrollback for all panes; drop the preserve-sessions gate.
