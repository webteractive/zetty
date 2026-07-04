# Per-Project Settings — Design

**Date:** 2026-07-04 · **Status:** shipped (v1 identity + overrides · v2 theme + layout templates · v3 env vars) ·
**Related:**
[`2026-07-04-layout-templates-design.md`](2026-07-04-layout-templates-design.md)
(its per-project `.zetty-layout.json` is consolidated into this design's
`.zetty/project.json`)

Let each project override selected global defaults and carry its own identity.
Editable from a **sidebar → "Project Settings…" sheet**. Settings split into
personal/machine prefs (kept private, per user) and a small shareable subset
that can travel with the repo — never secrets.

## Goals

- A per-project identity: custom **name**, **color**, and **icon**, so a
  multi-project sidebar and tab bar are instantly readable.
- Per-project **overrides** of global defaults where it matters: **theme**,
  **preserve-sessions**, **notifications**.
- Per-project **environment variables** injected into the project's panes,
  with secret values never committed to a repo.
- Per-project **default layout template** + **startup command** (shareable),
  reusing the layout-templates work.
- One editing surface — a sheet opened from the project's sidebar context menu
  — plus a quick inline **Rename**.

## Non-goals

- A global "Projects" tab in the Settings window (context-menu sheet only for
  v1; a cross-project overview can come later).
- Arbitrary per-project fonts (font stays uniform per the font-settings design).
- Arbitrary hex project colors — a **curated palette** only (see Design-rules).
- Syncing settings across machines / a team settings server. The repo file is
  the only sharing mechanism, and only for non-secret, shareable keys.

## Override model

Each setting is one of two kinds:

- **Project-only** (no global equivalent): `name`, `color`, `icon`, env vars,
  layout template, startup command. Optional value; unset = feature off.
- **Override of a global default** (`theme`, `preserve-sessions`,
  `notifications`): **tri-state** — *Follow global* (default) / *On* (or a
  value) / *Off*. Modeled as an `Optional` where `nil` = follow global.

**Precedence, most-specific wins:**

```
project private override  →  project repo file  →  global config  →  built-in default
```

## Storage (hybrid)

### Private central store (per user / machine)

New `~/Library/Application Support/zetty/project-settings.json`, a
`ProjectSettingsStore` mirroring `WorkspaceStore`
(`Sources/ZettyCore/Persistence/WorkspaceStore.swift`). A dictionary keyed by
**canonical absolute `rootPath`** — chosen over the project UUID because
rootPath survives remove-and-re-add and is the durable identity a user thinks
in. Holds:

- `name`, `color`, `icon`
- `themeOverride` (scheme name or nil)
- `preserveSessionsOverride` (Bool? — nil = follow global)
- `notificationsOverride` (tri-state `Bool?`): *Follow global* (nil) uses the
  global `notify-sound`/`notify-badge`/`notify-system` settings; *Off* (false)
  suppresses all agent alerts for this project; *On* (true) forces all three.
  A finer per-channel model is a possible later refinement, out of scope for v1.
- `env` (`[String: String]` — **values live here only**)

### Optional in-repo file (shareable, git-committable)

`.zetty/project.json` at the project root. Holds shareable-only keys:

- `layoutTemplate` (the `LayoutTemplate` from the layout-templates design)
- `startupCommand` (default new-pane command / new-tab cwd)
- `envNames` (`[String]` — declares expected variable names, like
  `.env.example`; **never values**)

The repo writer has **no code path that serializes env values** — secret
non-leakage is enforced by construction, not by discipline. When both a repo
file and private overrides exist, private wins per the precedence chain.

This consolidates the standalone `.zetty-layout.json` proposed in the
layout-templates design: that file becomes the `layoutTemplate` field of
`.zetty/project.json`. The layout-templates plan will be updated to reference
this file.

## Model & code seams

- **`ProjectSettings`** — new pure Codable struct in `ZettyCore` holding the
  overridable fields as optionals; the unit-tested heart of the feature.
- **`ProjectSettingsStore`** — private-file load/save, keyed by rootPath;
  mirrors `WorkspaceStore`. Loaded in `AppDelegate` alongside
  `workspaceStore`/`configStore` (`AppDelegate.swift:52,35`).
- **`Project.name`** (`Sources/ZettyCore/Model/Project.swift:45`) and
  **`Project.preserveSessions`** (`:49`) already exist — this surfaces them.
  `ProjectRuntime.name` (`WorkspaceModel.swift:5`) receives the override
  (falling back to `rootPath.lastPathComponent`).
- **Effective-value resolver** — a pure function
  `effectiveSettings(project:, global:) -> ResolvedProjectSettings` applying the
  precedence chain, so the App layer asks one place for "what applies to this
  project right now."

## Runtime application

| Setting | Mechanism |
|---|---|
| **Name** | Override feeds `ProjectRuntime.name`; sidebar/tab rendering unchanged. Inline **Rename** context-menu item edits it directly. |
| **Color + Icon** | A swatch/dot + glyph on the sidebar project row (`SidebarView` cell, ~`:895` `configure(...)`); optionally tints the active project's tab bar. Curated palette only. |
| **Theme override** | On project activate (`selectProject`), if `themeOverride` is set, apply that `ZColorScheme` via the existing single theme path (`SurfaceRegistry.terminalTheme` + `ZTheme.current`); else the global scheme. Switching projects re-themes the whole app live — a deliberate, strong context signal. |
| **Preserve-sessions** | Effective per-project value feeds `AppDelegate.applySessionPreservation` (`:397`) / the session command provider, replacing the global-only read. |
| **Layout template** | Applied on project open per the layout-templates design; template sourced from `.zetty/project.json` or the private store. |
| **Env vars** | Injected into every pane spawned in the project — **mechanism to be confirmed** (see Open questions). |
| **Notifications** | The needs-attention path (`AttentionInbox` → sound/badge/system) checks the effective per-project override before firing. |

## UI — sidebar context menu + sheet

`SidebarView`'s project-row context menu (`SidebarView.swift:226`, currently
just "Remove Project…" at `:537`) gains, above the existing separator:

- **Rename** — inline edit of the row's name (writes `name` override).
- **Project Settings…** — opens a sheet scoped to the clicked project.

The sheet (a new `ProjectSettingsSheetController`, styled per `ZTheme`/DESIGN.md)
groups fields:

- **Identity** — Name (text); Color (curated swatch picker); Icon (SF Symbol /
  emoji picker).
- **Appearance** — Theme (popup: *Follow global* + scheme list).
- **Sessions** — Preserve sessions (segmented: *Follow global / On / Off*);
  Layout template (*None* / saved / **Save current as template** / from repo
  file if present).
- **Environment** — key/value editor; values persist to the private store only.
- **Notifications** — *Follow global / On / Off* (single tri-state; see
  storage for semantics).

## Design-rules considerations (DESIGN.md / CLAUDE.md)

- **Project color:** DESIGN rule 3 reserves the accent for focus/brand and rule
  8 fixes semantic colors (green/yellow/red/purple) to meaning. A free per-project
  hue would collide. **Resolution:** a curated `ProjectColor` palette of ~8
  distinct hues chosen to avoid the semantic tokens, exposed as `ZTheme`-derived
  tokens rather than inline hex (rule 1). The project color tints a small row
  indicator/swatch, **not** the focus accent — the accent-dot focus semantics
  are untouched.
- **Theme override re-themes chrome on project switch:** consistent with the
  existing "all-or-nothing scheme" rule (7) and the single theme-application
  path (rule 6); it just changes *when* the scheme is chosen (per active
  project rather than globally).

## Open questions / investigation before/within the plan

- **Env-var injection mechanism (heaviest unknown).** Zetty's panes use
  libghostty's `.exec` backend (`SurfaceRegistry.swift:158`
  `TerminalSurfaceOptions(backend: .exec, workingDirectory:)`), which inherits
  the app environment. Per-project vars need either (a) a `TerminalConfiguration`
  env directive if libghostty-spm exposes one, or (b) a spawn wrapper that
  `export`s the vars before exec, or (c) injection into the zmx-session command
  when preserve-sessions is on. The implementation plan must confirm which is
  available before committing — handled with the same honesty as the search
  plan's libghostty gap, not hand-waved.
- **Env + preserve-sessions interaction:** a preserved session captures its
  environment at first creation; changing project env later won't affect a
  running session until it's recreated. Document this like the layout-template
  "inject once" rule.

## Edge cases

- **rootPath key collisions / moves:** if a project's directory is moved, its
  private settings orphan (keyed by old path). Acceptable for v1; a "settings
  follow rename" nicety is out of scope. Re-adding at the same path restores
  settings — the intended behavior of path-keying.
- **Missing / malformed `.zetty/project.json`:** `decodeIfPresent` + schema
  version; on failure, log and ignore the repo file (fall back to private +
  global). A bad repo file must never brick project open.
- **Theme override naming an unknown scheme:** fall back to global; no error UI
  (mirrors font-settings' invalid-family handling).
- **Env values in the repo file:** impossible by construction (no serializer);
  if a hand-edited repo file contains a `env` values map, it is ignored on read.
- **Notifications override off + agent needs attention:** the pane still shows
  the yellow dot (visual state is not a notification); only sound/badge/system
  are gated.
- **Unset everything:** a project with no settings behaves exactly as today
  (folder name, global theme/sessions/notifications). Zero-config unchanged.

## Testing

`ZettyCoreTests` (pure — the bulk):

- `ProjectSettings` Codable round-trip; forward-compat `decodeIfPresent`;
  schema-version mismatch.
- `effectiveSettings(project:, global:)`: precedence chain for each tri-state
  (follow/on/off) and each project-only field; repo-file vs private-override
  wins; unset → global.
- `ProjectSettingsStore`: keyed by canonical rootPath; add/read/remove;
  re-add-at-same-path restores.
- Repo-file writer emits **no** env values (assert the serialized JSON has no
  values map even when the model carries one).

App layer (sheet, sidebar swatch/icon, live re-theme on project switch, env
injection, notification gating) is manual — GUI capture is TCC-blocked. Manual
script per phase below.

## Rollout (phased)

**v1 — identity + light overrides (mostly scaffolded):**
1. `ProjectSettings` + `ProjectSettingsStore` + `effectiveSettings` + tests.
2. Sidebar **Rename** + **Project Settings…** sheet shell; Name field wired.
3. Color/icon (curated palette tokens) on the sidebar row.
4. Preserve-sessions override → session path; Notifications override → attention
   path.

**v2 — appearance + layout:**
5. Theme override applied on project activate (re-theme live).
6. Layout template field + `.zetty/project.json` repo file (consolidating the
   layout-templates plan's file).

**v3 — environment (pending mechanism confirmation):**
7. Env-var editor + private-store persistence + `envNames` in repo file.
8. Injection into spawned panes via the confirmed mechanism; document the
   preserve-sessions "captured at creation" rule.
