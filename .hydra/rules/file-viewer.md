---
paths:
    - "Sources/ZettyCore/Viewer/**"
    - "Sources/ZettyCore/Diagnostics/**"
    - "App/Sources/App/FileViewerLoader.swift"
    - "App/Sources/App/FileViewerOverlay.swift"
    - "App/Sources/App/PathHoverTracker.swift"
    - "App/Sources/App/ZettyLog.swift"
commands:
    - "zetty view"
triggers:
    - "changing the file viewer peek or cmd-click path handling"
    - "the file viewer shows a blank panel"
    - "opening files from terminal output"
---

# Read-only file viewer

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

⌘-click a file path in terminal output (or `zetty view <path>[:line[:col]]`) and
Zetty routes by **content**, not extension:

- **Text** → a transient read-only overlay, syntax-highlighted, scrolled to the
  line (marked with `bg3`). Esc, the header ✕, or a click outside closes it. At
  most one peek per window; a second click replaces its content.
- **Not text** (binary, or past `viewer-max-bytes`) → no overlay at all; the file
  goes to its default app (a PDF to Preview). The overlay is created only *after*
  the load resolves, so a PDF never flashes an empty panel.
- **Launchable** (installer, disk image, compiled binary) → revealed in Finder,
  never opened. See the security note below.
- **Unreadable** → the overlay shows the reason; there's nothing else to offer.
- **Nothing to draw** → also a reason, never an empty panel. See below.

There is **no write path**. The footer's `Open in ▾` hands the file to a real
editor at the right line (`EditorURLScheme` builds the per-editor URL: `zed://`,
`vscode://`, `cursor://`, `windsurf://`, `txmt://` — the last via `URLComponents`,
because `urlPathAllowed` permits `&`/`=` and a filename like `Q&A.md` would
otherwise corrupt the query). Editors with no scheme get a plain `NSWorkspace`
open, which cannot carry a line. The menu also lists the system default app
after a separator (suffixed `(default)` on the editor entry instead when it's
already in the roster, so it never appears twice). The status bar's own
`Open ▾` pill is untouched and still opens the focused pane's *directory*.

Pure logic in `ZettyCore/Viewer/`: `FilePathToken` (token extraction + the
`path:line:col` grammar, also used by the CLI), `PathResolution` (ordered
candidates — pane cwd, project root, `a/`/`b/` diff prefixes; the caller stats
them so ZettyCore stays filesystem-free), `FileViewerContent` (NUL sniff over the
first 8 KB, byte cap, 20 000-line cap), `ANSIText` (SGR → styled runs, incl.
256-colour and truecolor), `TerminalCellGeometry` (point↔cell, both directions —
lifted out of `CopyModeController`, which now uses it), `EditorURLScheme`,
`ExternalOpenPolicy` (launch-vs-reveal). App layer: `FileViewerLoader` (bounded
read + the highlight subprocess off-main, `bat` located explicitly because a GUI
app's `PATH` is too thin), `FileViewerOverlay` (the panel), `PathHoverTracker`
(⌘-hover underline + ⌘-click, one local event monitor). Config reaches the
controller through `viewerSettingsProvider` (set by `AppDelegate`), never a
re-read of the file.

## Security: paths are untrusted input

A path can come from arbitrary terminal output (a log, a `curl` response), so
⌘-click turns *reading output* into *asking LaunchServices to open a file*.
Displaying a document is harmless; installing or executing one is not.
`ExternalOpenPolicy` (pure, 11 tests) therefore reveals rather than launches:
an extension denylist (`pkg`/`dmg`/`iso`/`xip`/`msi`, `jar`/`class`, bundle
types, `scpt`/`workflow`/`command`/`exe`, …) plus **Mach-O and universal-binary
magic bytes** in both byte orders — the magic check is the load-bearing one,
since a compiled binary usually has no extension at all. Most of the surface is
already closed by accident: shell scripts are *text* (so they render in the
viewer) and `.app` bundles are *directories* (refused outright).

## The highlighter is a foreign theme — treat its colours as untrusted

The highlight subprocess has **no idea which scheme Zetty is showing**. `bat`
run without a TTY can't detect a background, falls back to a dark theme, and
emits xterm 231 — *pure white* — for ordinary body text. `ANSIText` maps
256-cube indexes 16–255 to **absolute RGB** (only 0–15 resolve to `ZTheme`
tokens), so that white reached the text view untouched and rendered white-on-
white on every light scheme: the peek looked *empty*, not merely mis-coloured,
which is why it was reported as "the file tree shows nothing" rather than as a
theming bug. Two layers now, both regression-tested, and **both are needed** —
the first fixes the default, the second covers the commands Zetty can't
configure:

1. **`HighlightTheme.environment(isDark:)`** (ZettyCore) pins `BAT_THEME` /
   `BAT_THEME_DARK` / `BAT_THEME_LIGHT` to the ACTIVE scheme's axis. It is an
   env var, not an appended `--theme`, because the command is user-configurable
   and Zetty must not rewrite its arguments — a user's own `--theme` still
   wins, and the vars are inert for a non-bat highlighter. `isDark` is read on
   the main actor in `presentFileViewer` and threaded through
   `FileViewerLoader.load`; it cannot be re-derived off-main, since the scheme
   can be pinned per project.
2. **`ColorLegibility`** (ZettyCore, pure) is the backstop: in
   `FileViewerOverlay.color(for:)` the `.rgb` branch drops any colour whose
   WCAG contrast against `bg1` falls below 1.6, handing the run to the `fg`
   fallback. The threshold is deliberately far below WCAG's 4.5 — syntax themes
   legitimately dim comments, and forcing those up would flatten the palette
   into one colour. Only `.rgb` is checked; indexes 0–15 are already `ZTheme`
   tokens and legible by construction.

## An empty body is a bug, not a state

A peek whose attributed body has **zero characters** paints the panel, the
header, the dividers and the text view's `bg1` — and no glyphs. That is
pixel-for-pixel indistinguishable from a broken renderer, which is why it was
reported as "the file viewer modal shows nothing" rather than as an empty file,
and why it survived one round of fixes aimed at colour. Three guards now make it
unreachable, and all three are needed because they close different holes:

1. **`FileViewerContent` classifies a zero-byte read as `.empty`**, not
   `.text("")`. A pure case rather than an empty string, so the caller is forced
   to say *why* there's nothing.
2. **The loader tells an empty file from an unread one** by comparing the bytes
   it got against the size on disk. They are not the same event: a file whose
   contents can't be materialised (an evicted cloud placeholder is the case that
   motivated this) is listed, stat-ed and opened exactly like a real one, so
   reporting it as "empty" would hide a read failure. It also **falls back to
   the plain text when the highlighter yields no printable characters** — before,
   a highlighter that emitted only escape sequences replaced real content with
   an empty panel, since `highlight() ?? text` only falls back on *nil*, not on
   output that parses to no runs.
3. **The overlay routes an EMPTY run list to the message branch**, with a
   `"Nothing to display"` backstop. The loader always supplies a reason; this is
   what keeps a silent blank panel unreachable if a future path forgets to.

Don't "simplify" any of these back — `.empty` folded into `.text("")`, or the
overlay's `!runs.isEmpty` dropped, each restores the silent blank panel on its
own.

## The peek narrates itself (`ZettyLog.viewer`)

Blank-peek reports keep arriving as a screenshot of an empty panel, which is the
same picture for a failed read, a hostile highlighter, invisible colours, and a
text view laid out at zero height — and none of it reproduces locally, because
the inputs are the reporter's scheme, their `bat`, and their file. So the path
from ⌘-click to glyphs logs each step through `ZettyLog` (App layer), and every
line lands in **two** sinks:

- **`os.Logger`** (subsystem `co.webteractive.zetty`, category `viewer`) —
  collectable after the fact with `log show --predicate 'subsystem ==
  "co.webteractive.zetty"'`. Never `print`/`NSLog`: free when unread, kept on
  release builds, persisted. The no-debug-`NSLog` convention below still stands.
- **`DiagnosticRing`** (`ZettyCore/Diagnostics/`, pure + tested, lock-guarded
  because the file load runs off-main) — a bounded tail behind the peek footer's
  **Copy diagnostics**. Both are needed: the log store rotates within days and
  asking a reporter to run a `log show` incantation loses most of them, while
  the ring is one click but dies with the process.

- **Call sites pass plain `String`s; `ZettyLogger` marks them `.public` in one
  place.** `Logger` redacts dynamic strings by default and a log of `<private>`
  is worthless in a report. The message has to exist as text for the ring
  anyway, so nothing is lost by building it eagerly. What's recorded is local
  state (paths, theme, highlighter) and stays on the Mac until the user pastes
  it.
- **File contents are never logged** — only counts: chars, non-whitespace `ink`,
  run count, distinct resolved foreground hexes, `illegible`/`uncoloured` tallies
  from `ColorLegibility`. `ink` is what separates "real text rendered
  invisible" from "there was nothing to render".
- **Geometry is logged one run-loop turn later** (`logGeometry`), because at
  `show()` time Auto Layout hasn't run and the panel is still zero-sized. It
  reads `textLayoutManager`, never `layoutManager` — touching the latter
  downgrades the view to TextKit 1.

## Gotchas, all deliberate

- **`viewer-highlight-command` / `viewer-max-bytes` are reserved keys.** They must
  stay in `AppConfig`'s `switch`; forwarded to ghostty, either would fail its
  all-or-nothing validation and drop the whole config including the per-surface
  `command`, stranding preserved sessions. Regression-tested.
- **Detection needs preserve-sessions.** Text comes from zmx capture (the same
  `captureLines` closure copy mode uses); a plain-shell pane gets no underline
  and no ⌘-click, silently. `zetty view` works regardless.
- **Rows are approximate.** Capture is `history` + `suffix(rows)`, so wrapped
  lines can shift which line is believed to be under the cursor. It fails
  closed — a drifted row rarely yields a path that both parses and resolves —
  but two nearby lines both holding valid paths can peek the wrong one.
- **Hit detection walks the real view hierarchy** (`contentView.hitTest`, then up
  to an `AppTerminalView`). A per-surface `bounds.contains` check is wrong twice
  over: `allSurfaceIDs` spans every non-hibernated project and tab, whose views
  aren't in the window, and an open overlay would be peeked *through*.
- **The underline is drawn over the surface,** not into it: libghostty owns the
  text, so a transparent child view with `hitTest` → nil paints the 1pt accent
  line and can never swallow a click. `rebuildSurfaceNodeView` calls
  `pathHover.reset()` for the same reason it exits copy mode.
- **⌘-click is consumed only when it opens something,** so an ordinary ⌘-click
  still reaches the terminal. `acceptsMouseMovedEvents` is enabled lazily on
  `flagsChanged` (a key event, delivered regardless), so tracking works even if
  the window didn't exist at install time.
- **A stale load can't win.** Each peek bumps `fileViewerRequest`; a slow
  highlighter landing after a newer click is dropped.
- Esc works because `KeyInterceptor` passes keys through when the first
  responder `is NSTextView`; `applyTheme()` skips its focus-restore while the
  overlay is open, and the overlay reclaims first responder when content lands.

## Do not reintroduce a TextKit stack

The body is a **plain `NSTextView` in an `NSScrollView`**, configured exactly like
`FileCopyBackSheet` — no hand-built `NSTextStorage`/`NSLayoutManager`/
`NSTextContainer`, no manual frame, no `isVerticallyResizable`, no
`NSRulerView`. An earlier version hand-rolled a TextKit 1 stack purely so a
line-number ruler could reach `layoutManager`; text laid out correctly (glyph
count, font, colour and frame all measured sane) but **never composited** — even
a forced background colour refused to draw. Four fixes chased it before the
stack itself turned out to be the cause. Line numbers were dropped rather than
rebuilt, which also keeps copied text clean.

**The one thing the text view must configure is `autoresizingMask = [.width]`.**
A clip view widens its document view only through that mask, and a bare
`NSTextView()` has none. The overlay is built and filled while it is still
detached and zero-sized, so without the mask the text view keeps that 0 width
when the panel is finally laid out: the container is 0 wide, nothing lays out,
and the peek paints a blank panel with the whole file sitting in its storage —
`show:` logs real `chars`/`ink`, and `show: geometry` shows `text={{0,0},{0,H}}`
inside a full-width `clip`. **macOS 26 widens the document view implicitly, so
this reproduces only on macOS 15** — it shipped through 0.1.34 and was reported
as yet another blank peek. `ProjectSettingsSheet.envTextView` is the in-repo
reference for the correct setup; `FileCopyBackSheet.diffView` had the same
omission and was fixed with it. `isVerticallyResizable` still needs no touching
(it is already `true` by default) — the mask is the whole fix.

Deferred: ⌘F find-in-file, Reveal in Finder for text files, back/forward history
between peeks, a viewer pane in the split tree, magic-byte *format* detection
(the text/binary split is still a NUL heuristic), and any form of editing.
