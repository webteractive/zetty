---
paths:
    - "Sources/ZettyCore/Settings/**"
    - "App/Sources/App/ProjectSettingsSheet.swift"
    - "App/Sources/App/IconPicker.swift"
triggers:
    - "changing per-project settings, color, icon, or theme overrides"
    - "layout templates or .zetty/project.json"
    - "per-project env vars or startup commands"
---

# Per-project settings

> Split out of `CLAUDE.md` / `AGENTS.md` (which stay under the agent context
> limit). This file is authoritative: edit it here, then run `hydra sync`.

Right-click a project row → **Rename…** / **Project Settings…** (name, curated
color, SF Symbol icon, preserve-sessions + notifications tri-states). Pure
model in `ZettyCore/Settings/` (`ProjectSettings` · `ProjectSettingsFile` ·
`ProjectSettingsStore` · `ProjectSettingsResolver`); private JSON at
`~/Library/Application Support/zetty/project-settings.json` keyed by
**canonical rootPath** (survives remove/re-add; a moved directory orphans its
settings — accepted for v1). Precedence: project override → global config →
default. App wiring: `AppDelegate.resolvedSettings(for:)` +
`updateProjectSettings(_:for:)`; per-pane preserve decision inside
`applySessionPreservation`'s provider via `WorkspaceModel.project(containing:)`
(affects NEW panes only); notification gating at the fire site
(sound/banners) and in `publishAttentionCount` (dock badge) — the in-app
bell/inbox and status dots are never gated. Palette ids in
`ZTheme.projectPalette` (8 curated hues, distinct from accent + semantic
status colors, appearance-reactive: each id carries a dark/light hex pair).

v2/v3 additions (same design doc):
- **Appearance + theme overrides** — modeled on the global keys:
  `ProjectSettings.appearanceOverride` ("system"/"dark"/"light") +
  `themeDarkOverride`/`themeLightOverride` (scheme per axis), each
  independently nil = follow global. Resolved in
  `AppDelegate.applyThemeForActiveProject()` — the single visual decision
  point (transient, never persisted into the global config; unknown scheme
  names fall back to the global choice; it also pins/releases
  `NSApp.appearance` for the EFFECTIVE axis). Activation hook:
  `TerminalViewController.onActiveProjectChanged` (project select — incl.
  tab-row clicks that switch projects — add, remove). OS appearance flips
  arrive via a distributed-notification observer (KVO on
  `effectiveAppearance` goes silent while pinned), and `osIsDark` reads the
  system default when pinned so a pinned project can't poison the next
  project's resolution.
- **Layout templates** — `LayoutTemplate`/`TemplateNode` (pure, mirrors
  `SurfaceNode`; panes carry root-relative cwds + startup commands;
  `capture(from:rootPath:)` / `tabList(rootPath:)`). Storage: the
  `layoutTemplate` field of the git-committable `.zetty/project.json`
  (`ProjectFile`/`ProjectFileIO` — shareable keys ONLY: layoutTemplate,
  startupCommand, envNames; no env-values field exists, and a hand-edited one
  is dropped on read) with a global fallback (`LayoutTemplateStore`,
  `layout-template.json` in App Support). Applied on `add-project` (replaces
  the single-pane seed) or on demand from the sheet's Layout row
  (Save Current / Apply / Clear). Startup commands inject once via
  `registry.sendText` ~0.8s after the pane spawns
  (`pendingStartupCommands`, in-memory only — a relaunch never re-runs
  commands into preserved sessions).
- **Env vars** — `ProjectSettings.env` (values in the PRIVATE store only);
  injected as repeated ghostty `env` directives per surface
  (`SurfaceRegistry.surfaceEnvironment` → `config.custom("env", "K=V")`).
  New panes only — a preserved zmx session captures env at first creation.
  Sheet editor: KEY=VALUE lines.
