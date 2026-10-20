---
paths:
    - "Sources/ZettyCore/Keybindings/**"
    - "App/Sources/App/KeyInterceptor.swift"
    - "App/Sources/App/CopyModeController.swift"
triggers:
    - "changing prefix keys, key bindings, or copy mode"
    - "adding a keyboard shortcut"
---

# tmux-style prefix keys and copy mode

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

`Ctrl+B` (configurable) arms a one-shot prefix; the next key drives Zetty:
`%`/`"` split · h/j/k/l or arrows focus panes directionally · `o` cycle ·
`x` close · `z` zoom (transient, never persisted) · `c`/`n`/`p`/`1-9` tabs ·
`,` inline tab rename · `[` copy mode · `]` paste · `e` file tree · prefix-twice sends the
literal prefix to the pty · Esc cancels. Copy mode is modal and vi-keyed
(h/j/k/l/w/b/e/0/$/g/G, Ctrl+U/D/F/B paging, `v`/`V` select, `y`/Enter yank,
`q`/Esc exit).

**A multiplexer in the pane owns the prefix.** Unbound keys after the prefix
are swallowed (`consumeNoop`), so tmux's `Ctrl+B d` used to vanish entirely.
`KeyBindingEngine.handle(_:paneForeground:)` passes the prefix through while
the receiving pane's foreground process is in `prefixOwningMultiplexers`
(tmux, screen), gated by `zetty-tmux-passthrough` (default true). The
foreground comes from the 3s zmx/`ps` probe (`foregroundBySurface`), so it
needs a preserved pane and lags tmux starting; tmux behind `ssh` reads as
`ssh` and still needs prefix-twice. The closure is evaluated only on the
prefix chord — keep it that way, it walks the responder chain.

Key routing: one `NSEvent.addLocalMonitorForEvents(.keyDown)` in
`KeyInterceptor` (App) runs before any view, translates the event to a
`KeyChord`, and asks `KeyBindingEngine` (`ZettyCore/Keybindings/`, pure +
unit-tested) for a resolution — passthrough, or consume + `BindingCommand`
dispatched into `PaneActions`/`TerminalViewController`/`CopyModeController`.
Guards: events outside the main window, active IME composition, and
text-editing first responders (palette, rename, settings) always pass
through. Status bar shows `PREFIX`/`COPY`/`ZOOM` chips.

Copy mode's keyboard cursor **is a Ghostty selection**: `CopyModeController`
synthesizes in-process mouse press/drag/release into `AppTerminalView` at
computed cell centers (`TerminalViewState.surfaceSize` supplies cell pixel
metrics), so Ghostty renders the highlight natively. Scrolling/copy/paste use
`performBindingAction` (`scroll_page_up`, `scroll_page_fractional:±0.5`,
`scroll_to_top/bottom`, `copy_to_clipboard`, `paste_from_clipboard`). Word
motions scan viewport lines from zmx capture (preserved sessions); without
one they fall back to coarse 8-column jumps. Known limits: panes running
mouse-capturing TUIs may swallow the synthetic clicks; wrapped lines make
zmx-derived rows approximate. Pure cursor math lives in `CopyModeCursor`.

Config: `prefix = <chord>` plus repeated `bind = <chord> <command>` /
`copy-bind = <chord> <command>` lines (additive over the tmux-canonical
defaults in `BindingCommand.default*Table`; no unbind). Chords are
case-sensitive for characters (`G` = shift+g), case-insensitive for modifier
words/named keys; bad lines are skipped and collected in
`KeyBindingConfiguration.issues`. Accepted lines re-emit through
`AppConfig.rendered()` so runtime persists don't drop them. Reload (⇧⌘,)
rebuilds the tables and exits any armed/copy state.

## Adding a keyboard shortcut

**Never add a keyboard shortcut without first proving the chord is free.**
Zetty has four independent shortcut surfaces, and a silent collision is the
usual failure — AppKit just lets the first responder win, so the new binding
"sometimes doesn't work". Before adding one, check **all four**:

```sh
# 1. Native menu key equivalents (character + modifier mask must BOTH match
#    an existing pair to collide — ⌘B, ⌃⇧B and ⇧⌘B are three distinct chords)
grep -B4 'keyEquivalentModifierMask' App/Sources/App/AppDelegate.swift \
  | grep -E 'title:|keyEquivalent'
# 2. Prefix layer (Ctrl+B then a key)
grep -n 'bind("' Sources/ZettyCore/Keybindings/BindingCommand.swift
# 3. Copy mode
grep -n 'copyBind\|defaultCopyTable' -A40 Sources/ZettyCore/Keybindings/BindingCommand.swift
# 4. The user's own config — `bind` / `copy-bind` lines are additive
grep -E '^(prefix|bind|copy-bind)' ~/.config/zetty/config
```

Then state the result before writing code, and say what the chord costs.
Two costs are easy to miss:

- **A native equivalent is resolved in `NSApplication.sendEvent` *before* the
  terminal surface sees the event**, so a Control-modified chord bound here
  permanently stops that keystroke reaching the pty. Prefer ⌘-based chords for
  menu items — Command is never sent to the shell — and leave Control chords
  to the prefix layer.
- **A well-known chord spent here is spent for good.** Say what else it
  conventionally means and let the user decide. Recorded precedent: ⇧⌘F is
  "find in files" in VS Code and Zed, and it is deliberately spent on Toggle
  File Tree; a future project-wide content search needs a different chord
  rather than stealing this one back. ⇧⌘G is spent on Toggle Tile Mode,
  costing find-previous and Finder's Go to Folder — plain ⌘G was left free on
  purpose, for the viewer's deferred find-in-file. ⇧⌘J is spent on the tile
  manager, beside ⌘J for Sessions (the two docked drawers), costing Chrome's
  Downloads and Xcode's Reveal in Project Navigator.
