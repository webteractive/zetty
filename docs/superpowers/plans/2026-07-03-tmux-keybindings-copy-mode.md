# tmux-style Keybindings + Copy Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ctrl+B prefix layer (panes/tabs/zoom/rename) + vi-style copy mode with keyboard cursor, fully remappable from `~/.config/zetty/config`, per `docs/plans/2026-07-03-tmux-keybindings-copy-mode-design.md`.

**Architecture:** Pure decision core in `ZettyCore/Keybindings/` (KeyChord parsing, KeyBindingEngine state machine, binding tables from config) + geometric directional focus in the layout model. App layer adds one `NSEvent` local key monitor that consults the engine and dispatches commands to existing `PaneActions`/`TerminalViewController` plus a new `CopyModeController` that drives the Ghostty surface via public API (`performBindingAction`, synthesized `NSEvent` mouse calls, `TerminalViewState.surfaceSize` cell metrics).

**Tech Stack:** Swift 6, AppKit, GhosttyTerminal (libghostty-spm), Tuist. Tests: `swift test` (ZettyCore, headless) + `mise exec -- tuist test` for app-target checks.

## Global Constraints

- Regenerate after adding files: `mise exec -- tuist clean && mise exec -- tuist generate --no-open` (stale-manifest gotcha).
- ZettyCore stays pure — no AppKit imports anywhere under `Sources/ZettyCore/`.
- Never hardcode colors/fonts in UI: `ZTheme.current.<token>Color`, `ZTheme.monoFont` for chrome (design rules 1–2).
- No debug `NSLog`/`print` in committed code.
- Never commit without asking Glen.
- Chord matching rule: for printable-character keys, shift is baked into the character (`%` is shift+5) — compare ctrl/alt/cmd only and ignore shift; for named keys (arrows, escape, enter, tab, space) shift is significant.
- Copy-mode Ghostty verbs used (pinned libghostty): `scroll_page_up`, `scroll_page_down`, `scroll_page_fractional:±0.5`, `scroll_to_top`, `scroll_to_bottom`, `adjust_selection:{left,right,up,down,beginning_of_line,end_of_line,home,end,page_up,page_down}`, `copy_to_clipboard`, `paste_from_clipboard`.

---

### Task 1: KeyChord — parse/normalize key chords (ZettyCore)

**Files:**
- Create: `Sources/ZettyCore/Keybindings/KeyChord.swift`
- Test: `Tests/ZettyCoreTests/KeyChordTests.swift`

**Interfaces:**
- Produces:
  - `struct KeyChord: Hashable, Sendable { var key: ChordKey; var modifiers: ChordModifiers }`
  - `enum ChordKey: Hashable, Sendable { case character(Character); case named(NamedKey) }`
  - `enum NamedKey: String, Sendable { case up, down, left, right, escape, enter, tab, space, backspace }`
  - `struct ChordModifiers: OptionSet, Hashable, Sendable { ctrl, shift, alt, cmd }`
  - `static func parse(_ s: String) -> KeyChord?` — accepts `ctrl+b`, `%`, `shift+cmd+x`, `escape`, `ctrl+space`; case-insensitive; `nil` on junk (`ctrl+`, empty, multi-char non-named).
  - `func matches(_ other: KeyChord) -> Bool` — equality with the shift rule from Global Constraints.
  - `var configDescription: String` — round-trips to config syntax.

- [ ] Write tests: parse round-trips (`ctrl+b`, `%`, `"`, `shift+up`, `cmd+1`, `ctrl+space`, `escape`), invalid inputs → nil, shift-insensitive match for `.character`, shift-sensitive for `.named`.
- [ ] Run `swift test --filter KeyChordTests` — fails (type missing).
- [ ] Implement KeyChord.
- [ ] `swift test --filter KeyChordTests` passes.

### Task 2: BindingCommand + default tables (ZettyCore)

**Files:**
- Create: `Sources/ZettyCore/Keybindings/BindingCommand.swift`
- Test: `Tests/ZettyCoreTests/BindingCommandTests.swift`

**Interfaces:**
- Produces:
  - `enum BindingCommand: Equatable, Sendable` — prefix table: `splitVertical, splitHorizontal, focusLeft, focusRight, focusUp, focusDown, cyclePanes, closePane, zoomPane, newTab, nextTab, previousTab, selectTab(Int), renameTab, enterCopyMode, paste, sendPrefixLiteral, cancelPrefix`; copy-mode table: `copyCursorLeft/Right/Up/Down, copyWordForward, copyWordBackward, copyWordEnd, copyLineStart, copyLineEnd, copyScrollTop, copyScrollBottom, copyHalfPageUp/Down, copyPageUp/Down, copyBeginSelection, copyBeginLineSelection, copyYank, copyExit`
  - `init?(configName: String)` + `var configName: String` (kebab-case: `split-vertical`, `focus-left`, `select-tab-3`, `copy-word-forward`, …)
  - `static let defaultPrefixTable: [KeyChord: BindingCommand]` and `defaultCopyTable: [KeyChord: BindingCommand]` — exactly the design-doc tables (tmux canon), including `1`–`9` → `selectTab(n)`.

- [ ] Tests: configName round-trip for every case incl. `select-tab-N`; default tables contain the design-doc bindings (spot-check `%`, `"`, `z`, `[`, `]`, `,`, `v`, `y`, `g`, `G`, `ctrl+u`, arrows+hjkl in both tables).
- [ ] Fail → implement → pass (`swift test --filter BindingCommandTests`).

### Task 3: KeyBindingEngine state machine (ZettyCore)

**Files:**
- Create: `Sources/ZettyCore/Keybindings/KeyBindingEngine.swift`
- Test: `Tests/ZettyCoreTests/KeyBindingEngineTests.swift`

**Interfaces:**
- Consumes: `KeyChord`, `BindingCommand`, tables.
- Produces:
  - `enum KeyMode: Equatable, Sendable { case normal, prefixArmed, copyMode }`
  - `enum KeyResolution: Equatable, Sendable { case passthrough; case consume(BindingCommand); case consumeNoop }`
  - `final class KeyBindingEngine` (ZettyCore, no AppKit):
    - `init(prefix: KeyChord, prefixTable: [KeyChord: BindingCommand], copyTable: [KeyChord: BindingCommand])`
    - `private(set) var mode: KeyMode`
    - `func handle(_ chord: KeyChord) -> KeyResolution` — normal: prefix→arm(consumeNoop), else passthrough. Armed: prefix chord→`consume(.sendPrefixLiteral)`+disarm; bound→consume+disarm (`enterCopyMode` switches mode to `.copyMode`); escape→`consume(.cancelPrefix)`+disarm; unbound→`consumeNoop`+disarm. copyMode: bound in copyTable→consume (`copyYank`/`copyExit` return mode to normal); unbound→consumeNoop (swallow everything — copy mode is modal).
    - `func reset()` — back to `.normal` (config reload / focus loss / pane close).
    - `func exitCopyMode()` — external exits (pane closed).

- [ ] Tests: every transition above, incl. prefix-twice literal, unbound-key disarm, copy-mode swallows unbound, `reset()` from every mode.
- [ ] Fail → implement → pass (`swift test --filter KeyBindingEngineTests`).

### Task 4: Config parsing — `prefix`, `bind`, `copy-bind` (ZettyCore)

**Files:**
- Create: `Sources/ZettyCore/Keybindings/KeyBindingConfiguration.swift`
- Modify: `Sources/ZettyCore/Config/AppConfig.swift` (reserved keys + parse + default-file comment block)
- Test: `Tests/ZettyCoreTests/KeyBindingConfigurationTests.swift` (+ extend `AppConfigTests`)

**Interfaces:**
- Produces:
  - `struct KeyBindingConfiguration: Equatable, Sendable { var prefix: KeyChord (default ctrl+b); var prefixTable: [KeyChord: BindingCommand]; var copyTable: [KeyChord: BindingCommand]; var issues: [String] }`
  - `AppConfig.keybindings: KeyBindingConfiguration` — built from `prefix = <chord>` and repeated `bind = <chord> <command-name>` / `copy-bind = <chord> <command-name>` lines. Value format: first whitespace-separated token = chord, rest = command name. User lines override the default table per-chord (additive; no unbind). Bad chord/unknown command → line ignored + message appended to `issues`.
- AppConfig reserved keys grow by `prefix`, `bind`, `copy-bind` (ghostty defines none of these; `keybind` still forwards).

- [ ] Tests: defaults when no lines; `prefix = ctrl+space` honored; `bind = X split-vertical` overrides only `X`; repeated binds accumulate; `copy-bind` targets copy table; junk lines → `issues` non-empty and line skipped; ghostty `keybind =` still lands in `config.ghostty`.
- [ ] Fail → implement → pass (`swift test --filter KeyBindingConfigurationTests && swift test --filter AppConfigTests`).
- [ ] Update `AppConfig.defaultFileContents` + `rendered()` comment block documenting `prefix`/`bind`/`copy-bind` (commented examples only, no active lines).

### Task 5: Directional focus + pane cycle (ZettyCore)

**Files:**
- Modify: `Sources/ZettyCore/Model/Layout.swift`, `Sources/ZettyCore/Model/PaneTree.swift`
- Test: `Tests/ZettyCoreTests/LayoutDirectionalFocusTests.swift`

**Interfaces:**
- Produces:
  - `enum FocusDirection: Sendable { case left, right, up, down }`
  - `Layout.frames(in unit: CGRect = 0,0,1,1) -> [UUID: CGRect]` — normalized rects by walking splits with ratios (SplitDirection.vertical = side-by-side → x-axis cut; horizontal = stacked → y-axis cut; match `SurfaceNodeView`'s existing interpretation — verify before coding).
  - `Layout.neighbor(of id: UUID, direction: FocusDirection) -> UUID?` — from the focused leaf's frame, candidates are leaves whose frame is strictly beyond the edge in that direction with vertical/horizontal overlap; pick the one with the largest overlap, tie-break nearest edge distance.
  - `PaneTree.focusNeighbor(_ direction: FocusDirection) -> Bool`, `PaneTree.cycleFocus() -> Bool` (document order of `layout.surfaces`, wraps).

- [ ] Tests: 2-way vertical split left/right + no-neighbor edges; nested 3-pane L-shape picks larger-overlap neighbor; up/down in horizontal splits; cycleFocus wraps; focusNeighbor false for single pane.
- [ ] Fail → implement → pass (`swift test --filter LayoutDirectionalFocusTests`).

### Task 6: Zoom state (ZettyCore) + zoomed rendering (App)

**Files:**
- Modify: `Sources/ZettyCore/Model/PaneTree.swift` (transient `zoomedSurfaceID: UUID?` — excluded from `CodingKeys` so it never persists; cleared by `splitFocused`/`closeFocused` when stale; `toggleZoom()` zooms the focused surface / unzooms)
- Modify: `App/Sources/App/SurfaceNodeView.swift` call-site (wherever the tree renders — render only the zoomed leaf's view when `zoomedSurfaceID` is set; verify entry point in `TerminalViewController` rebuild path first)
- Test: `Tests/ZettyCoreTests/PaneTreeZoomTests.swift`

**Interfaces:**
- Produces: `PaneTree.zoomedSurfaceID: UUID?`, `PaneTree.toggleZoom() -> Bool` (false when <2 panes), auto-unzoom on split/close of the zoomed pane, Codable round-trip drops zoom.

- [ ] Tests: toggle on/off, false with single pane, split-while-zoomed unzooms, close-zoomed-pane unzooms, `JSONEncoder`/`Decoder` round-trip loses zoom.
- [ ] Fail → implement core → pass.
- [ ] App: render single-pane when zoomed (guard: zoomed id must still exist, else fall back to full tree). Status: zoom indicator = reuse tab title area or status bar chip `ZOOM` (mono font, `bg3` chip, accent text — same component as Task 8's chips).
- [ ] `mise exec -- tuist generate --no-open && xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build` succeeds.

### Task 7: NSEvent→KeyChord translation + KeyInterceptor (App)

**Files:**
- Create: `App/Sources/App/KeyInterceptor.swift`
- Modify: `App/Sources/App/AppDelegate.swift` (install after workspace restore; feed config)
- Test: `Tests/ZettyCoreTests` already covers decisions; app-side translation gets a small pure helper test if extractable — otherwise verified by build + live use.

**Interfaces:**
- Consumes: `KeyBindingEngine`, `AppConfig.keybindings`, `PaneActions` selectors on `TerminalViewController`, `CopyModeController` (Task 9 — stub protocol `CopyModeDriving` now: `func enter()`, `func exit()`, `func perform(_ command: BindingCommand)`).
- Produces:
  - `final class KeyInterceptor` — `init(engine:dispatcher:)`, `func install()` / `deinit` removes monitor (`NSEvent.addLocalMonitorForEvents(matching: .keyDown)`).
  - Translation: `charactersIgnoringModifiers` → `.character` (first scalar, lowercased for letters; keep symbols verbatim); keyCodes/specials → `.named` (arrows 123–126, escape 53, return 36, tab 48, space 49, delete 51); modifierFlags → `ChordModifiers`.
  - Guards, in order: key window is the terminal window; no marked text (`(NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true`); command palette/settings/rename field not active (firstResponder is not an `NSTextView`/`NSTextField` editor **unless** engine.mode == .copyMode is false — simplest: if firstResponder is a text editor, passthrough unless mode != .normal was armed from the terminal; keep rule: text-editor firstResponder → force `.passthrough` and `engine.reset()`).
  - `onModeChange: ((KeyMode) -> Void)?` → drives status chips.
  - Dispatcher enum switch: pane/tab commands call existing `@objc` funcs (`splitVertical`, `closePane`, `newTab(nil)`, `selectNextTab`, `selectPreviousTab`, `selectTab(at:)`, `renameTab` — reuse tab-bar rename path found at `TerminalViewController.swift:558`), focus commands call new PaneTree methods + `rebuildAndFocus()`, `sendPrefixLiteral` sends `\u{02}` via `SurfaceRegistry.sendText`, copy commands forward to `CopyModeDriving`.

- [ ] Implement + wire; build via tuist generate + xcodebuild (expect clean).
- [ ] Manual smoke (Glen or `zetty` CLI where possible): Ctrl+B c opens tab; Ctrl+B % splits; Ctrl+B arrows move focus; Ctrl+B Ctrl+B reaches shell (verify with `cat -v` showing `^B`).

### Task 8: Status-bar mode chips (App)

**Files:**
- Modify: `App/Sources/App/StatusBarView.swift` + `TerminalViewController.refreshStatusBar()` wiring

**Interfaces:**
- Produces: `StatusBarView.setKeyMode(_ mode: KeyMode)` — renders `PREFIX` / `COPY` chip (hidden for `.normal`): `ZTheme.monoFont`, `bg3` fill, accent text + accent glow per design rules 3/9; also `ZOOM` chip via `setZoomed(Bool)` (from Task 6).

- [ ] Implement; build passes; visual check by Glen post-install.

### Task 9: CopyModeController (App) + cursor math (ZettyCore)

**Files:**
- Create: `Sources/ZettyCore/Keybindings/CopyModeCursor.swift` (pure math)
- Create: `App/Sources/App/CopyModeController.swift`
- Test: `Tests/ZettyCoreTests/CopyModeCursorTests.swift`

**Interfaces:**
- Produces (core):
  - `struct CopyModeCursor: Equatable, Sendable { var row: Int; var col: Int }` (viewport cells)
  - `enum CopyMotion { case left, right, up, down, lineStart, lineEnd, wordForward, wordBackward, wordEnd }`
  - `CopyModeCursor.moved(_ motion: CopyMotion, grid: (rows: Int, cols: Int), lines: [String]) -> CopyModeCursor` — clamped; word motions scan `lines[row]` (space-delimited runs, vi-like: `w` next word start, `b` prev word start, `e` word end; crossing lines at edges).
- Produces (app): `final class CopyModeController: CopyModeDriving`
  - `enter()`: focused pane's `AppTerminalView` + `TerminalViewState.surfaceSize` → place cursor at bottom-left-ish default (row = rows-1, col 0); represent as 1-cell selection via synthetic mouse: `NSEvent.mouseEvent(with: .leftMouseDown/…)` targeting cell center pixel → point conversion (`cellWidthPixels / backingScale`), call `view.mouseDown/mouseDragged/mouseUp` directly (in-process, no TCC).
  - Motions without anchor: re-place the 1-cell selection at the new cursor. With anchor (`v`): extend via a synthetic drag from anchor cell to cursor cell (one mouseDown at anchor kept "open" is fragile — instead redo down@anchor→drag@cursor→up each motion). `V`: anchor at line start, cursor to line end, extend rows on j/k.
  - Scroll verbs + page motions: `performBindingAction` (`scroll_page_up` etc.); after scroll, re-place cursor (selection) at same viewport cell.
  - Word motions need viewport text: `zetty capture`'s underlying path — check `ControlSocketServer`/`sendInput` for how capture reads pane text; if no public viewport-text API exists on AppTerminalView, fall back: word motions via repeated `adjust_selection:left/right`? NO — keep simple: derive `lines` from `NSPasteboard` round-trip is unacceptable; instead reuse whatever `zetty capture` uses (it exists — `capture` CLI reads pane output). Verify that mechanism first; if capture reads via zmx, viewport lines for word motions come from `zmx` capture for preserved panes and word motions degrade to char motions when unavailable (documented).
  - `copyYank`: `performBindingAction("copy_to_clipboard")` → exit; paste: `performBindingAction("paste_from_clipboard")`.
  - Exit paths: `Esc`/`q`/`y`, pane close, focus change, config reload → `engine.exitCopyMode()` + clear selection (single synthetic click) + `scroll_to_bottom`.

- [ ] Core tests: motion clamping at all edges, word motions incl. multiple spaces/punctuation-as-word-chars, line start/end, empty line.
- [ ] Fail → implement core → pass (`swift test --filter CopyModeCursorTests`).
- [ ] App controller implemented; build passes.
- [ ] Live verification checklist for Glen (documented in PR/summary): enter `[`, hjkl moves highlight, `v`+motion grows selection, `y` puts text on clipboard, `G`/`g` bottom/top, Ctrl+U/D half-page, `q` exits + rejoins live tail.

### Task 10: Config reload + lifecycle integration

**Files:**
- Modify: `App/Sources/App/AppDelegate.swift` (reload path rebuilds engine tables + `engine.reset()`), `TerminalViewController` (pane close/focus-change hooks call `copyMode.exit()` when active; `statusSnapshot()` untouched)

- [ ] ⇧⌘, reload applies changed `prefix =` live (manual check).
- [ ] `swift test` (full ZettyCore suite) green; `mise exec -- tuist test` green; full xcodebuild green.

### Task 11: Docs
- Modify: `CLAUDE.md` (short bullet under Configuration for `prefix`/`bind`/`copy-bind` + one line in feature list), `AGENTS.md` (key-routing architecture paragraph: monitor → engine → dispatcher, copy-mode mechanism + verbs used), `README.md` feature bullet.
- [ ] Docs updated in same style/altitude as neighboring sections.

### Task 12: Install + handoff
- [ ] Rebuild, `ditto` to `/Applications`, verify `ZettyBuildCommit` matches HEAD (memory: Glen expects the /Applications copy refreshed).
- [ ] Summarize verification checklist for Glen; ask about committing (never auto-commit).

## Self-Review Notes

- Spec coverage: prefix table ✔ (T2/T7), copy mode ✔ (T9), remap config ✔ (T4), zoom ✔ (T6), rename ✔ (T7 reuses existing UI), chips ✔ (T8), IME/edge cases ✔ (T7 guards, T10 lifecycle), spike → folded into T9 as verify-first steps on capture/selection mechanics since interactive GUI probing is Glen-side.
- Type names consistent across tasks (KeyChord/BindingCommand/KeyBindingEngine/KeyBindingConfiguration/CopyModeCursor/CopyModeDriving).
- Open risk (accepted in design): synthetic-selection behavior is verified live by Glen; fallback is Approach C for copy mode only.
