# Broadcast / Synchronized Input — Design

**Date:** 2026-07-04 · **Status:** Proposed

Type once, send the same keystrokes to many panes at once — tmux
`synchronize-panes` / iTerm2 "broadcast input". Plus an agent-aware variant
that targets only the panes running AI agents. This is the highest-ROI feature
in the current backlog: the entire injection mechanism already exists (the
`zetty send` path), so broadcast is "run the existing single-pane send against
N panes instead of one."

## Goals

- A toggle that enters **broadcast mode**: while active, normal typing in the
  focused pane is mirrored to every pane in the target set.
- Three target scopes: **current tab**, **whole workspace**, **agents only**
  (panes with a resolved `AgentKind`).
- Always-visible state: a `BROADCAST` chip in the status bar so the mode is
  never silent — typing-goes-everywhere must be obvious.
- Remappable prefix binding (`bind = <chord> broadcast-toggle`), consistent
  with the existing prefix layer.

## Non-goals

- A per-pane "included in broadcast" multi-select UI (iTerm2's checkboxes).
  The scope is a single mode with a scope selector, not arbitrary set editing.
- Broadcasting mouse events, selections, or scroll — keystrokes only.
- Forcing background/unspawned panes to spawn just to receive input (see Edge
  cases — they no-op).
- CLI `zetty send --all/--agents` (listed as an optional follow-up, not part of
  the first cut).

## Architecture

The load-bearing discovery: `SurfaceRegistry.sendText(_:to:)`
(`App/Sources/ZettyGhostty/SurfaceRegistry.swift:196`) already writes bytes
into a libghostty surface via the `text:` binding action (not
`ghostty_surface_text`, so `\r` and control keys survive). `zetty send` and
paste both ride it. Broadcast loops it over a set of surfaces. **No libghostty
or PTY work.**

### 1. Command (`ZettyCore` — pure, tested)

`BindingCommand` (`Sources/ZettyCore/Keybindings/BindingCommand.swift:6`) gains:

- `case broadcastToggle` — cycle broadcast off → current-tab → off.
- `case broadcastAgentsToggle` — off → agents-only → off.

Register both in `namesByCommand` (`:53`) as `"broadcast-toggle"` /
`"broadcast-agents-toggle"`; this auto-wires `configName`/`init?(configName:)`
so `bind = <chord> broadcast-toggle` parses for free. No default prefix key is
assigned (typing-everywhere is dangerous enough that it should be opt-in via
explicit `bind` or the command palette / menu), but this is a one-line change
if we decide otherwise.

Broadcast is deliberately **not** a fourth `KeyMode`: keystrokes must keep
flowing (the engine stays `.normal` and returns `.passthrough`); the *App*
layer decides to fan out. Modeling it as a `KeyMode` would fight the design and
buy nothing.

### 2. Broadcast state (App — `TerminalViewController`)

New stored state next to `foregroundBySurface`
(`TerminalViewController.swift:85`):

```
enum BroadcastScope { case off, currentTab, workspace, agents }
private var broadcastScope: BroadcastScope = .off
```

`var isBroadcasting: Bool { broadcastScope != .off }`.

Target resolution (computed on each send, so panes opened/closed mid-broadcast
are handled):

- **currentTab** → `paneTree.layout.surfaces` (`:49`).
- **workspace** → flatten `workspace.projects[*].tabList.trees[*].layout.surfaces`
  (the pattern `locate(shortID:)`/`surface(withShortID:)` already use,
  `:1258`/`:1272`).
- **agents** → the above, filtered by
  `agentDetector.state(for: surface.id).kind != nil` (`agentDetector` at
  `:77`; same read the status snapshot does at `:1023`).

### 3. Interception (App — `KeyInterceptor`)

`handle(_:)` (`App/Sources/App/KeyInterceptor.swift:127`) is the single
NSEvent monitor. Insert broadcast fan-out **after** the existing guards
(wrong window / text-editing first responder / IME composition, `:128–147`)
and **only when** `engine.handle(chord)` resolves to `.passthrough` and
`isBroadcasting`:

1. Encode the chord once → bytes, reusing the `sendPrefixLiteral` logic
   (`:222–233`, control-letter → C0 byte, else the character) plus
   `KeyNotation.encode` (`Sources/ZettyCore/CLI/KeyNotation.swift:30`) for named
   keys (enter/tab/arrows).
2. `viewController.broadcast(bytes)` → loop `registry.sendText(bytes, to:)` over
   the resolved target set (**including** the focused pane).
3. `return nil` to swallow the native event, so the focused pane isn't doubled.

The IME / text-editing guards must short-circuit *before* broadcast — never
mirror during composition or while a Zetty text field is first responder.

`perform(binding:interceptor:)` (`:176`) gains
`case .broadcastToggle: toggleBroadcast(.currentTab)` and
`case .broadcastAgentsToggle: toggleBroadcast(.agents)`.

### 4. Action + menu + palette (App — `PaneActions`)

`toggleBroadcast(_ scope:)` (idiomatic home is `PaneActions.swift`, mirroring
`zoomPane` at `:68`): flip `broadcastScope`, then `refreshStatusBar()`. Expose
as a menu item (View menu, near Zoom) and a command-palette entry so it's
reachable without a binding.

### 5. Status chip (App — `StatusBarView`)

Add `broadcastChip` beside `modeChip`/`zoomChip`
(`App/Sources/App/StatusBarView.swift:30`); include it in the style arrays
(`:116`, `:326`) and the leading stack (`:124`). New
`setBroadcasting(_ scope: BroadcastScope)` mirrors `setZoomed(_:)` (`:264`),
showing ` BROADCAST `, ` BROADCAST · ALL `, or ` BROADCAST · AGENTS `.

**Deliberate design deviation (call out at review):** broadcast is a
"dangerous" mode — every keystroke goes to N shells. Rather than the accent
glow the other chips use (DESIGN.md rule 3), style this chip with the
`yellowColor` attention token so it reads as a warning. `refreshStatusBar()`
(`:624`) calls `setBroadcasting(broadcastScope)` alongside the existing
`setZoomed`.

## Edge cases

- **Background / unspawned panes:** `sendText` returns `false` when a pane has
  no live view yet (`SurfaceRegistry.swift:197`). Broadcast silently skips
  them — we do not force-spawn (forcing spawn on keypress would be surprising
  and slow). Document this; revisit if dogfooding wants it.
- **Focused pane doubling:** avoided by swallowing the native event and
  including the focused surface in the fan-out. All panes receive identical
  bytes.
- **Prefix key while broadcasting:** the engine resolves the prefix chord to
  `.prefixArmed` *before* the broadcast branch (broadcast only fires on
  `.passthrough`), so `Ctrl+B x` etc. still drive Zetty locally and are not
  broadcast. Good — you can still manage panes mid-broadcast.
- **Chord→bytes fidelity:** covered for letters, control combos, and named
  keys. Exotic modified keys / dead keys are best-effort; IME is excluded by
  the guards. Note the limitation rather than chase 100%.
- **Empty / single-pane target set:** broadcasting to one pane == normal
  typing; harmless. Agents scope with zero agents is a no-op (chip still shows,
  so the user sees why nothing's happening).
- **Panes closing mid-broadcast:** targets are recomputed per send from the
  live model, so a closed pane simply drops out.

## Testing

`ZettyCoreTests` (pure):

- `BindingCommand`: `broadcast-toggle` / `broadcast-agents-toggle` round-trip
  through `configName` ↔ `init?(configName:)`; `bind = ... broadcast-toggle`
  parses to the right command (extend `BindingCommandTests`).
- Target-set resolution helper (extract a pure function taking the surface list
  + agent-state lookup → target `[UUID]`) unit-tested for currentTab /
  workspace / agents-only, including the zero-agents case.
- Chord→bytes encoding shares the `sendPrefixLiteral`/`KeyNotation` path; add
  cases for enter, ctrl+c, a letter, an arrow.

App layer (chip visibility, fan-out over live surfaces, IME short-circuit) is
manual — GUI capture is TCC-blocked here. Manual script: split 3 panes, toggle
broadcast, type `echo hi`↵, confirm all three receive it and the focused pane
isn't doubled; toggle agents-only with two agent panes + one shell, confirm
only the agents receive input.

## Rollout

1. Commit 1: `BindingCommand` cases + name mapping + pure target-set helper +
   tests.
2. Commit 2: `TerminalViewController` broadcast state/fan-out + `KeyInterceptor`
   interception + `PaneActions` toggle + menu/palette entries.
3. Commit 3: `StatusBarView` chip + warning styling + `refreshStatusBar` wiring.
4. *(Optional follow-up, separate plan)* CLI `zetty send --scope
   tab|all|agents` — needs `PaneSelector` to gain a multi-resolve sibling
   (`resolveAll(in:) -> [Pane]`) in `ControlProtocol`/`ControlCLI`.
