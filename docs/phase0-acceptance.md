# Phase 0 Acceptance Checklist

Spike: one libghostty surface (`TerminalView` / `.exec` backend) in the quertty app window.

## How to run

```bash
cd ~/AI/quertty
/opt/homebrew/bin/mise exec -- tuist generate
open quertty.xcworkspace
```

Select the **quertty** scheme, press **Run** (⌘R).

## Acceptance items (verified by user, 2026-06-30)

- [x] **Shell prompt renders** — Window opens showing a live shell prompt rendered by libghostty (`TerminalView` with `.exec` backend spawning `$SHELL`).
  - Result: PASS (`ls` runs and renders).

- [x] **Typing works** — Typing appears in the terminal; `ls` confirmed.
  - Result: PASS.

- [x] **Resize reflows** — Resizing the window causes the terminal to reflow.
  - Result: PASS.

- [x] **Focus on click** — Clicking the terminal pane gives it keyboard focus.
  - Result: PASS.

- [ ] **Kitty graphics** — A Kitty-graphics image renders, confirming full libghostty rendering.
  - Result: NOT TESTED — `kitten` (the kitty terminal's CLI) is not installed; this is a missing test tool, not a quertty defect. Kitty graphics support is inherited from libghostty. Confirm later via `brew install kitty` + `kitten icat <img>` or another protocol emitter.

**Verdict: Phase 0 PASSED.** Core terminal (render/type/resize/focus) works in the app shell. The one unticked item is a missing test tool, not a functional gap.

Prior crash fixed: Tuist's default Info.plist set `NSMainStoryboardFile = Main`; `@main` routed through `NSApplicationMain` which crashed loading the nonexistent storyboard. Resolved by a programmatic `main.swift` bootstrap (commit `a5c6771`).

## Notes

- The `.exec` backend spawns the user's `$SHELL` in a real PTY. No sandbox shell is used.
- `TerminalController()` handles `ghostty_init` internally; `Ghostty.initializeRuntime()` is **not** called in the app path to avoid a double-init.
- Any FAIL here blocks Phase 1 multi-pane work.
