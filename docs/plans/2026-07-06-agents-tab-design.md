# Agents Tab (spawnable agents per project) — Design

**Date:** 2026-07-06 · **Status:** Approved

Add an **Agents** tab to the per-project Settings sheet that lists the coding
agents/harnesses Zetty can launch, each with a toggle and an editable launch
command. When a project has ≥1 agent enabled, creating a new tab/pane shows an
**inline chooser overlay** inside the fresh pane: pick one of the enabled agents
(injects its command) or "Normal shell" (plain terminal).

## Decisions (settled with Glen)

| Question | Decision |
|---|---|
| Supported agents (v1) | claude, codex, hermes, gemini, opencode, pi, cursor |
| Catalog | A new `SpawnableAgent` catalog in `ZettyCore`, **independent of** `AgentKind` (detection) |
| Chooser UX | **Inline overlay** inside the freshly-spawned pane (not a menu/sheet) |
| Prompt frequency | **Always ask** when ≥1 agent enabled (no per-project default in v1) |
| Launch command | **Editable per agent** (defaults to the catalog command) |
| Scope | **Per-project**, stored in the private `project-settings.json` |
| Triggers | Interactive **new tab** + **splits** only |

## Spawnable-agent catalog

Pure `ZettyCore` value list — id, display name, default command:

| id | displayName | defaultCommand |
|---|---|---|
| `claude` | Claude Code | `claude` |
| `codex` | Codex | `codex` |
| `hermes` | Hermes | `hermes` |
| `gemini` | Gemini | `gemini` |
| `opencode` | opencode | `opencode` |
| `pi` | Pi | `pi` |
| `cursor` | Cursor Agent | `cursor-agent` |

**Why separate from `AgentKind`:** `AgentKind` drives detection (tab logos,
status dots) and today lacks `pi`/`cursor`; extending it would force logo +
detection work now. Spawning is a different concern, so it gets its own catalog.

**Known v1 gap (deliberate):** a spawned `cursor-agent`/`pi` pane won't get a
detection logo/status until `AgentKind` learns them — a separate follow-up. The
tab still shows whatever title the CLI emits.

## Model

`ProjectSettings` gains one optional field:

```swift
public var agents: [ProjectAgent]?   // nil/empty → feature off (no overlay)
```

```swift
public struct ProjectAgent: Codable, Sendable, Equatable {
    public var id: String        // SpawnableAgent id ("claude", "cursor", …)
    public var command: String   // launch command (defaults to catalog value)
}
```

Presence in the array = **enabled**. Toggling an agent on appends
`ProjectAgent(id:, command: catalog default)`; editing its field updates
`command`; toggling off removes it. Unknown ids (a catalog entry removed later)
decode fine and are ignored at render/spawn time. Stored per canonical rootPath
in the existing private `project-settings.json` (same store as `env`), not the
shareable repo file — this is a personal preference.

A pure resolver returns the effective, catalog-validated enabled agents for a
project (drops unknown ids, preserves order of the catalog):

```swift
SpawnableAgent.resolve(_ agents: [ProjectAgent]?) -> [(agent: SpawnableAgent, command: String)]
```

## UI — the Agents tab

A third `NSTabViewItem` ("Agents") in `ProjectSettingsSheet`, following the
existing General/Environment pattern. One row per catalog agent:

```
[✓] Claude Code   [ claude                 ]
[ ] Codex         [ codex                  ]   ← command field disabled until checked
[✓] Cursor Agent  [ cursor-agent           ]
…
```

- Left: an `NSButton` checkbox with the display name.
- Right: an `NSTextField` prefilled with the effective command; **enabled only
  when the checkbox is on**; empty field falls back to the catalog default on
  save.
- All chrome reads `ZTheme` tokens (no hardcoded colors); labels use the system
  font (standard controls).
- On **Save**, the sheet writes `agents` = the checked rows with their commands
  (dropping blanks to the default), alongside the other fields it already saves.

## UX — the inline chooser overlay

When a **newly, interactively** spawned pane belongs to a project with ≥1
enabled agent, an overlay is shown on top of that pane's terminal until the user
chooses:

- A centered card (bg2 surface, subtle border, accent title "Launch an agent?")
  with one button per enabled agent (display name) plus a **Normal shell**
  button and a hint ("Esc or type to dismiss").
- **Pick an agent** → `registry.sendText("<command>\r", to: surface)` (the shell
  is already running), then dismiss.
- **Normal shell / Esc / start typing in the pane** → dismiss, leaving the
  plain shell.
- The overlay is non-modal: it never blocks the terminal; dismissing always
  leaves a usable shell.

### Which spawns trigger it

Show the overlay **only** for a freshly-spawned pane that is all of:

1. created via an **interactive** action — `newTab(_:)`, `splitVertical`/
   `splitHorizontal` (the GUI paths), **not** the CLI `openNewTab`/`splitPane`;
2. in a project whose resolved `agents` is non-empty;
3. **not** carrying a pending layout-template startup command (templates own
   their command);
4. **not** a restored/reattached pane on relaunch (those already have a session).

`break-pane` re-parents an existing surface (same id, no new shell) → never
triggers.

### Mechanism

- TVC tracks `panesPendingAgentChoice: [UUID: [ (SpawnableAgent, command) ]]`.
- Interactive spawn actions, after creating the new surface, resolve the owning
  project's enabled agents (via a new `agentsProvider` closure wired from
  `AppDelegate.resolvedSettings`); if non-empty and no template command is
  pending, record the new surface id → enabled list.
- `SurfaceNodeView`/`LeafContainerView` shows the overlay for a container whose
  `surfaceID` is pending (the map is passed down on rebuild, mirroring how
  `focusedSurfaceID` flows). Choice/dismiss calls back into TVC, which injects
  (or not) and clears the entry, then refreshes.

## Data flow

```
Project Settings → Agents tab → Save
    → ProjectSettings.agents persisted (project-settings.json)

New tab / split (interactive)
    → new surface created
    → agentsProvider(project) non-empty & no template command?
        → panesPendingAgentChoice[surfaceID] = enabled agents
    → rebuild → LeafContainerView shows overlay
        → pick agent  → registry.sendText("cmd\r") → clear → dismiss
        → normal/esc/type → clear → dismiss
```

## Error handling

- **Empty command field on a checked row** → falls back to the catalog default
  on save (never persists an empty command).
- **Unknown agent id** in a decoded file → ignored by the resolver (tolerant
  decode; forward/backward compatible).
- **Agent binary not on PATH** → not Zetty's concern: the command is injected
  into the shell, which prints its own "command not found". We don't pre-check.
- **Overlay on a pane that closes before choice** → the pending entry is dropped
  with the surface (keyed by id; pruned on rebuild).
- **No enabled agents** → no overlay, no behavior change from today.

## Testing

- **`ZettyCore` (swift-testing):**
  - `SpawnableAgent.catalog` has the 7 expected ids + default commands;
    `byID` lookup; `cursor` → `cursor-agent`.
  - `SpawnableAgent.resolve` — drops unknown ids, preserves catalog order,
    applies per-agent command overrides, empty input → empty.
  - `ProjectSettings` round-trips `agents` through Codable; tolerant decode of
    an unknown-id entry; `isEmpty` still true when `agents` is nil/empty.
- **App layer** (not unit-tested — AppKit): verified live — enable Claude +
  Cursor for the Zetty project, open a new tab → overlay appears; pick Claude →
  `claude` runs; new split → overlay again; "Normal shell"/Esc/typing dismiss;
  a project with no agents shows no overlay; CLI `new-tab` shows no overlay.

## Non-goals (v1)

- Detection/logo parity for pi/cursor (separate follow-up on `AgentKind`).
- A per-project "default agent, don't ask" mode.
- Global (non-project) agent defaults.
- Passing extra args interactively (the editable command covers fixed args).
- Sharing the agent list via the repo `.zetty/project.json`.
