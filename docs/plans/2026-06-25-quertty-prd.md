# quertty — Product Requirements & Design

**Status:** Draft · **Date:** 2026-06-25 · **Owner:** glen@more.dev

---

## 1. Summary

**quertty** is a GUI terminal **multiplexer** for developers, built on **libghostty**
(Ghostty's embeddable terminal core) with a **Swift** application layer. It is a
single-window app that organizes work around **pinnable projects/directories**, each
holding multiple terminal **sessions** with **tabs and splits** — and it natively
**detects AI coding agents** (Claude Code, Codex, opencode, Aider, Gemini, hermes)
running in those sessions, surfacing their status (running / idle / needs-attention)
in the sidebar.

It is conceptually similar to Supacode, but with better sidebar/panel handling and a
status model driven by **harness hooks** rather than output scraping.

**Target platforms:** macOS first; Linux later (architecture protects this port).

### What makes it worth building (differentiators)
- AI agent detection with per-session status, surfaced in the sidebar (incl. "needs
  your attention / approval").
- Better sidebar panel handling than Supacode (pinnable projects, collapsible panels).
- tmux-style keybindings / modal control (later phase).
- Programmable / scriptable via a first-class `quertty` CLI + socket.
- Possible integrated editor + preview (later phase).

### Core principle
**We build the multiplexer shell, not the terminal.** Full libghostty provides VT
emulation, GPU rendering, font/text shaping, surfaces, and **both Kitty protocols
(keyboard + graphics)** for free. We never reimplement terminal internals.

---

## 2. Goals & Non-Goals

### Goals (v1)
- Pinnable projects/directories in a sidebar; multiple sessions per project.
- Tabs + horizontal/vertical splits per session, rendered by libghostty.
- Persisted layout; restore projects/sessions/tabs/splits on launch.
- AI agent **presence** detection for the six supported agents.
- Per-session **status** (running / idle / needs-attention) for harnesses that expose
  hooks; graceful degradation (presence only) for those that don't.
- A `quertty` CLI + local socket for **status reporting and scripting/control**.

### Non-Goals (v1)
- Windows support.
- Writing our own terminal emulation or renderer.
- A daemon / multi-client attach server (no client-server split).
- A full IDE.
- Cloud sync.
- Brittle output-pattern scraping as a load-bearing status mechanism.

---

## 3. Architecture

Three strictly-separated layers so the eventual Linux port is a UI re-skin, not a
rewrite.

```
┌─────────────────────────────────────────────┐
│  quertty (macOS app target)                   │  SwiftUI + AppKit
│  • Sidebar, tabs, split layout, status bar    │  — platform UI
│  • NSViewRepresentable hosts each surface      │
├─────────────────────────────────────────────┤
│  QuerttyCore (pure Swift, no UI imports)       │  the brain
│  • Project / Session / Tab / Surface model     │  — portable
│  • Layout tree + persistence                   │
│  • AI agent detection engine                   │
│  • PTY/process supervision (PTYBackend)         │
│  • quertty CLI socket server                    │
├─────────────────────────────────────────────┤
│  GhosttyKit (C-interop shim)                   │  thin binding
│  • Swift ⇄ libghostty C API (surface/apprt)    │  — to upstream
│  • surface create/resize/key/focus/draw         │
│  • libghostty callbacks → Core events           │
└─────────────────────────────────────────────┘
              ↓ links
        libghostty (full, vendored & pinned)
```

- **`QuerttyCore`** imports no AppKit/SwiftUI. It is the testable, portable heart —
  all state and logic live here.
- **`GhosttyKit`** is the only module that touches libghostty's C API. If the embedding
  API churns, the blast radius is one module.
- **macOS app** is the only platform-specific layer. A future `quertty-linux` (GTK)
  target swaps this layer and reuses `QuerttyCore` + `GhosttyKit` untouched.
- **Build/packaging:** Swift Package Manager workspace; libghostty pinned as a vendored
  binary/submodule at a known Ghostty commit; app bundled via Xcode.

---

## 4. libghostty integration

We build on **full libghostty** (not `libghostty-vt`), bound the same way Ghostty's own
macOS app binds it (the surface/apprt C API). This means GPU rendering, fonts, Kitty
keyboard + graphics, and surfaces are **inherited**. Multi-pane splits/tabs with full
libghostty are already proven by Ghostty's macOS app.

**GhosttyKit wraps the C API:**
- `ghostty_init()` / `ghostty_app_new()` — global runtime + app handle.
- `ghostty_surface_new(config)` — create a terminal surface bound to a Metal layer + PTY.
- `ghostty_surface_set_size()` / `_key()` / `_mouse_*()` / `_draw()` — drive it.
- A **callback table** for the embedder: title set, bell, clipboard, child-exited,
  open-URL, OSC notifications.

**`GhosttySurfaceView` (AppKit `NSView`)** backs one pane: owns a `CAMetalLayer`,
forwards key/mouse/resize/focus into `ghostty_surface_*`, and is hosted into SwiftUI via
`NSViewRepresentable`. libghostty's C callbacks are translated into Swift events that
`QuerttyCore` consumes (title → tab label; child-exited → mark surface dead; bell/OSC →
status signal).

**Risk controls:** the full embedding API is not officially frozen for third parties, so
we **pin to a known Ghostty commit**, isolate every C call in GhosttyKit, and prove the
seam in a **Phase 0 spike** before building on it. Upgrades are deliberate, tested
events — never floating. All calls into libghostty happen on its documented thread;
events marshal back to the main actor before touching UI.

---

## 5. Data model (`QuerttyCore`)

```
Project                       a pinned directory + its sessions
 ├─ id, name, rootPath
 ├─ isPinned, lastOpenedAt, sortOrder
 ├─ preserveSessions: Bool     (per-project override; see §7)
 ├─ defaultShell / env overrides (optional)
 └─ Session[]                 a working context within the project
     ├─ id, title
     └─ Tab[]
         └─ layout: SurfaceNode   (binary split tree)

SurfaceNode (recursive layout tree)
 ├─ .leaf(Surface)
 └─ .split(direction: .h|.v, ratio: Double, children: [SurfaceNode])

Surface                       one libghostty terminal pane
 ├─ id, workingDir, command
 ├─ ptyBackend: PTYBackend     (DirectPTY | DetachedPTY — see §7)
 ├─ ghosttySurfaceRef          (opaque, from GhosttyKit)
 └─ detectedAgent: AgentInfo?  (filled by AI detection engine)
```

**Decisions:**
- **Project → Session → Tab → Surface-tree.** Mirrors Supacode's hierarchy, but the top
  unit is a generic project/directory (not git-worktree-locked). Worktrees can become a
  project sub-type later.
- **Splits are a binary tree** — clean h/v nesting, ratio resizing, and "close pane →
  collapse parent."
- **Persistence:** the whole tree (projects, pins, layout, working dirs, sort order)
  serializes to JSON on disk (`~/Library/Application Support/quertty/`). On launch we
  restore the layout and re-spawn shells at saved working dirs. We do **not** persist
  scrollback or live processes in v1 (no daemon; sessions die with the window unless
  session preservation is enabled — see §7).
- **We do NOT model** scrollback, colors, fonts, or key-encoding — those are libghostty's
  internal state.

---

## 6. AI agent detection

Two separable problems: **which** agent is in a pane, and **what state** it's in.

### 6.1 Presence — universal, no cooperation needed
Per surface, poll the PTY's **foreground process group** (`tcgetpgrp` → resolve the
command via macOS `libproc`), every ~1–2s or on activity. Match the foreground command
against a **pluggable agent registry**:

```
AgentDescriptor
 ├─ kind, displayName, icon          (claude, codex, opencode, aider, gemini, hermes)
 ├─ binaryNames: [String]            // presence detection
 ├─ honorsHooks: Bool                // whether rich status is available
 └─ idleAfter: TimeInterval          // activity-based fallback
```

Supporting a new agent is a data change, not a code change. If no descriptor matches →
no icon.

### 6.2 Status — via harness hooks, not scraping
Rich per-session status (running / idle / needs-attention) is **pushed into quertty by
the harness's own hooks**, when the harness supports them. quertty exposes an integration
contract:

```
quertty sets per-surface env (mirrors Supacode's SUPACODE_SOCKET_PATH):
  QUERTTY_SOCKET   = /path/to/quertty.sock
  QUERTTY_SESSION  = <surface-id>

The `quertty` CLI reports status from inside a session:
  quertty status set --state needs-attention --reason "approval required"
  quertty status set --state running
  quertty status clear
→ socket → QuerttyCore updates that session's badge.
```

**Claude Code mapping (first supported harness):**

| Claude Code hook | quertty status |
|---|---|
| `Notification` (needs permission / input) | 🟠 needs-attention |
| `Stop` / `SubagentStop` (turn finished) | ⚪ idle |
| `UserPromptSubmit` / `PreToolUse` (working) | 🔵 running |

quertty ships **hook templates/installer snippets** per supported harness.

### 6.3 Graceful degradation (the rule)
- Harness exposes hooks → surface **real** status.
- Harness has no hooks → **presence only** (glyph, optional activity-based running/idle);
  **nothing claimed about attention**. No brittle scraping, no false badges.
- Terminal **bell / OSC-9** (from libghostty callbacks) is an optional generic
  attention fallback, not load-bearing.

### 6.4 Sidebar UX
- Each session/surface row: **agent glyph + state badge** (working spinner / dim idle /
  pulsing orange dot for attention).
- **Roll-up:** if any surface in a project needs attention, the *project* row shows the
  badge — a collapsed sidebar still surfaces "Claude needs you in project X."
- Optional global affordances: Dock badge + native notification on needs-attention.

---

## 7. Session preservation (`PTYBackend`)

PTY/process supervision is a `QuerttyCore` abstraction with two backends:

- **`DirectPTY`** (v1 default) — quertty owns the PTY; the session dies with the window.
- **`DetachedPTY`** (Phase 2) — the shell runs under a `zmx`/dtach-style detach-capable
  supervisor that holds the PTY and child process group behind a Unix socket. quertty
  connects the socket to a libghostty surface. On close the supervisor + child survive;
  on relaunch quertty reconnects. Configurable **per-project and globally**.

**Trade-off (dtach-family):** the *process* survives, not the screen buffer. Full-screen
apps (vim, `claude`, TUIs) redraw cleanly on reattach; a plain shell shows blank until
its next output. **Full scrollback restore** (quertty-side screen-buffer capture) is a
**future goal**, seeded by the per-surface output ring buffer already used for detection.

The `PTYBackend` seam is built in **v1** so Phase 2 drops in with no rework. libghostty
is agnostic to the backend — it just renders a PTY stream — so this is purely a
`QuerttyCore` concern.

---

## 8. `quertty` CLI + socket

A first-class CLI usable inside any session (modeled on Supacode's `supacode` CLI),
backed by a local socket server owned by `QuerttyCore`. Handles **both** status and
control from v1 — it is the foundation of the "programmable/scriptable" differentiator.

- **Status:** `quertty status set|clear …` (used by harness hooks).
- **Control:** open project, new tab, split surface, focus surface, list resources —
  enabling scripting and automation of layouts.

---

## 9. Roadmap

**Phase 0 — Foundation spike (de-risk first):** SPM workspace + 3-module skeleton;
vendor & pin full libghostty; GhosttyKit renders **one** surface in an `NSView` inside a
SwiftUI window with working keyboard/mouse/resize. Proves the riskiest seam first.

**Phase 1 — v1 (dogfoodable):**
- Project/Session/Tab/Surface-tree model + JSON persistence + layout restore
- Sidebar: pinnable projects, collapsible panels, session navigation
- Tabs + h/v splits, resize, focus, close→collapse
- `PTYBackend` seam + `DirectPTY`
- AI **presence** detection for Claude Code, Codex, opencode, Aider, Gemini, hermes
- `quertty` CLI + socket (status **and** control)
- Claude Code hook templates → status badges + project roll-up + native notifications
- *(inherited free: kitty keyboard + graphics, GPU rendering)*

**Phase 2:** `DetachedPTY` (zmx-backed, configurable session preservation) · tmux-style
keybindings + copy mode · layouts & workspaces (named save/restore) · more harness hook
templates.

**Phase 3+:** full scrollback restore · integrated editor + preview · **Linux/GTK** UI
layer (reusing `QuerttyCore` + `GhosttyKit`).

---

## 10. Testing strategy

- **`QuerttyCore` (pure Swift) carries the weight:** unit tests for the layout tree
  (split/close/resize/serialize round-trip), the per-session status state machine, the
  agent registry + presence logic (mock process/PTY fixtures), and CLI/socket command
  parsing.
- **GhosttyKit:** kept thin; a headless create/destroy-surface smoke test if feasible,
  otherwise manual verification.
- **App/UI:** minimal automated coverage — lean on core tests + dogfooding; optional
  snapshot tests for the sidebar.

---

## 11. Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Full libghostty embedding API not frozen for third parties; upstream churn | Pin commit, isolate in GhosttyKit, prove in Phase 0, deliberate upgrades |
| 2 | SwiftUI↔AppKit focus/key routing for hosted surfaces | De-risk early; reference Ghostty's macOS app implementation |
| 3 | Presence detection through wrappers (npm/node launchers, ssh, nested tmux) | Foreground-pgrp + child-process walk; accept edge cases |
| 4 | needs-attention reliability via heuristics | Solved by hook contract + graceful degradation (presence-only fallback) |
| 5 | Linux Swift-GUI story (no native toolkit) | Explicitly deferred; core/UI split keeps the port a re-skin |

---

## 12. Open questions

- Exact Ghostty commit/version to pin for Phase 0.
- Socket protocol shape and `quertty` CLI command grammar (finalize in Phase 1 design).
- Hook-template distribution: bundled installer vs. docs-only for v1.
- hermes / opencode / Aider / Gemini hook capabilities — which expose rich status vs.
  presence-only.
