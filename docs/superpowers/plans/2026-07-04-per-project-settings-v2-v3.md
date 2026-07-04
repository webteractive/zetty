# Per-Project Settings v2 + v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** v2 — per-project theme override applied on project activation, plus layout templates (capture/apply a tab-and-split arrangement with cwds + startup commands) carried by a shareable `.zetty/project.json`; v3 — per-project environment variables injected into panes.

**Architecture:** Extends the shipped v1 stack (ProjectSettings/store/resolver + sheet). Theme override rides the existing single theme path via a new transient (non-persisting) apply routed through the active project. Templates are pure `ZettyCore` types mirroring `SurfaceNode`, captured from / applied to `TabList`; startup commands are injected post-spawn via `registry.sendText` (never re-run on relaunch — the pending-commands map is in-memory only). `.zetty/project.json` is a tolerant-decode repo file whose writer cannot serialize env values by construction. Env vars inject per surface through ghostty's `env` config directive (`config.custom("env", "K=V")`), verified working end-to-end on the live app.

**Tech Stack:** Swift 6, swift-testing, AppKit, Tuist.

**Specs:** `docs/plans/2026-07-04-per-project-settings-design.md` (v2/v3 scope) + `docs/plans/2026-07-04-layout-templates-design.md`.

## Global Constraints

- `ZettyCore` stays pure (no AppKit). No debug prints. Fast loop: `swift test`; app build via xcodebuild; `tuist generate` after adding app files (`tuist clean` first on bogus manifest errors).
- **Commits require Glen's explicit OK.** No Co-Authored-By / session links / push / tag.
- Precedence unchanged: project private override → project repo file → global config → built-in default. **Repo file may carry ONLY shareable keys** (layoutTemplate, startupCommand, envNames) — never env values; enforced by the writer's type, and a hand-edited values map is ignored on read.
- Notifications/preserve semantics from v1 unchanged.
- Design deviations locked here: (a) startup commands are ALWAYS injected via `sendText` after spawn (both preserve modes) — keeps the shell alive under the command and unifies the code path; `Surface.command` is set on template-built surfaces only as the persisted record for re-capture. (b) Template tabs don't carry titles (YAGNI — titles come from running programs). (c) Global default template file (`layout-template.json` in App Support) is hand-editable; the in-app Save writes the active project's `.zetty/project.json`.

---

### Task 1 (v2a core): `themeOverride` in settings + resolver

**Files:** modify `Sources/ZettyCore/Settings/ProjectSettings.swift`, `ProjectSettingsResolver.swift`; tests in existing `Tests/ZettyCoreTests/ProjectSettingsTests.swift` / `ProjectSettingsResolverTests.swift`.

**Interfaces:** `ProjectSettings.themeOverride: String?` (scheme displayName; validated app-side); `ResolvedProjectSettings.themeOverride: String?` (pure pass-through).

- [ ] Failing tests: round-trip includes `themeOverride`; `isEmpty` false when only themeOverride set; resolver passes it through (nil default).

```swift
@Test func projectSettingsCarriesThemeOverride() throws {
    let settings = ProjectSettings(themeOverride: "Ember")
    #expect(!settings.isEmpty)
    let decoded = try JSONDecoder().decode(
        ProjectSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.themeOverride == "Ember")
}
```
```swift
@Test func resolverPassesThemeOverrideThrough() {
    #expect(ProjectSettingsResolver.resolve(nil, fallbackName: "x", global: AppConfig()).themeOverride == nil)
    #expect(ProjectSettingsResolver.resolve(
        ProjectSettings(themeOverride: "Ember"), fallbackName: "x", global: AppConfig()).themeOverride == "Ember")
}
```

- [ ] Implement: add the property (+ init param after `icon`, + `decodeIfPresent`), resolver field + passthrough. `swift test` all green.

### Task 2 (v2a app): transient theme path + activation hook + sheet row

**Files:** modify `App/Sources/App/AppDelegate.swift` (`applyScheme` ~line 275, `systemAppearanceDidChange` ~253, `updateProjectSettings`), `App/Sources/App/TerminalViewController.swift` (`selectProject(at:)` ~1771, add-project tail), `App/Sources/App/ProjectSettingsSheet.swift` (Theme popup between Icon and Preserve rows).

**Steps:**
- [ ] AppDelegate: add `applySchemeTransient(_:)` (the visual half: `ZTheme.scheme =`, window bg, `tvc.applyTheme()`) and `applyThemeForActiveProject()` (active project's resolved `themeOverride` → `ZColorScheme.named` → transient apply; unknown/nil → transient `resolvedScheme()`). Refactor `applyScheme(_:)` = persist half + `applyThemeForActiveProject()`; route `systemAppearanceDidChange` and the config-reload theme re-apply through `applyThemeForActiveProject()` too.
- [ ] TVC: `var onActiveProjectChanged: (() -> Void)?`, fired at the end of `selectProject(at:)` and after add-project activation; AppDelegate wires it to `applyThemeForActiveProject()`.
- [ ] `updateProjectSettings`: when the edited project is the active one, call `applyThemeForActiveProject()`.
- [ ] Sheet: `themePopup` — "Follow Global" + dark schemes + light schemes (displayNames); save maps index → name.
- [ ] Build + `swift test` green.

### Task 3 (v2b core): `LayoutTemplate` + capture/apply builders

**Files:** create `Sources/ZettyCore/Settings/LayoutTemplate.swift`; test `Tests/ZettyCoreTests/LayoutTemplateTests.swift`.

**Interfaces:**

```swift
public struct LayoutTemplate: Codable, Sendable, Equatable {
    public var schemaVersion: Int              // 1
    public var tabs: [TemplateTab]             // non-empty to be applicable
}
public struct TemplateTab: Codable, Sendable, Equatable {
    public var root: TemplateNode
}
public indirect enum TemplateNode: Codable, Sendable, Equatable {
    case pane(workingDir: String, command: String?)   // relative to root; "." = root
    case split(direction: SplitDirection, ratio: Double, first: TemplateNode, second: TemplateNode)
}
```

- `LayoutTemplate.capture(from: TabList, rootPath: String) -> LayoutTemplate` — cwds made root-relative (`.` for the root itself; an absolute cwd outside the root is kept absolute rather than faked relative); carries `surface.command`.
- `LayoutTemplate.tabList(rootPath: String) -> (tabList: TabList, commands: [UUID: String])?` — builds fresh `Surface`s (new UUIDs, absolute cwds; nonexistent subdir → project root), returns the per-surface startup commands for post-spawn injection; nil when `tabs` is empty. `TemplateNode` codes with explicit `type` discriminator (`"pane"`/`"split"`) via a keyed container so hand-authored JSON is readable.

- [ ] Failing tests: Codable round-trip incl. nested splits; capture makes cwds relative and rejects nothing (out-of-root stays absolute); apply resolves relative→absolute, missing dir → root, geometry preserved, commands returned keyed by the new surface ids; capture→apply round-trip structure-preserving; empty template → nil.
- [ ] Implement + `swift test` green.

### Task 4 (v2b core): `.zetty/project.json` + global template store

**Files:** create `Sources/ZettyCore/Settings/ProjectFile.swift`, `Sources/ZettyCore/Settings/LayoutTemplateStore.swift`; test `Tests/ZettyCoreTests/ProjectFileTests.swift`.

**Interfaces:**

```swift
public struct ProjectFile: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var layoutTemplate: LayoutTemplate?
    public var startupCommand: String?         // default new-pane command (v2 record; consumed with templates)
    public var envNames: [String]?             // declared variable NAMES only (like .env.example)
    // NOTE: no env-values field exists — the writer cannot leak secrets by construction.
}
public enum ProjectFileIO {
    public static func url(forProjectRoot rootPath: String) -> URL   // <root>/.zetty/project.json
    public static func load(projectRoot: String) -> ProjectFile?     // missing/corrupt → nil, never throws
    public static func save(_ file: ProjectFile, projectRoot: String) throws  // creates .zetty/
}
public struct LayoutTemplateStore {                                   // mirrors WorkspaceStore
    public init(directory: URL)                                       // layout-template.json
    public func load() -> LayoutTemplate?                              // missing/corrupt → nil
    public func save(_ template: LayoutTemplate) throws
}
```

- [ ] Failing tests: ProjectFile round-trip through a temp dir; corrupt file → nil; **hand-edited `"env": {"K":"secret"}` key in the JSON is ignored on read AND absent after a re-save**; template store round-trip + corrupt → nil.
- [ ] Implement (tolerant `init(from:)` everywhere) + `swift test` green.

### Task 5 (v2b app): apply-on-open + on-demand + startup-command injection

**Files:** modify `App/Sources/App/TerminalViewController.swift` (add-project paths ~1089/1540, pane-spawn callback, new `applyLayoutTemplate`), `App/Sources/App/AppDelegate.swift` (template resolution closure, palette/menu wiring), `Sources/ZettyCore/Keybindings/BindingCommand.swift` (+ `applyLayout`, `saveLayout` cases + parse tokens `apply-layout`/`save-layout`), palette registration site.

**Steps:**
- [ ] TVC: `var pendingStartupCommands: [UUID: String] = [:]` (in-memory only — relaunch can never re-run commands). On pane view spawn (the same callback that does the reattach resize nudge), if a pending command exists for the surface: `registry.sendText(surfaceID:, command + "\r")`, then remove it.
- [ ] TVC: `var layoutTemplateProvider: ((ProjectRuntime) -> LayoutTemplate?)?` — AppDelegate resolves `.zetty/project.json` first, then the global `LayoutTemplateStore`. In `addProjectFromURL`/`addProject`: when a template resolves, seed the project's `TabList` from `template.tabList(rootPath:)` instead of the single default pane and merge the returned commands into `pendingStartupCommands`.
- [ ] TVC: `func applyLayoutTemplate()` — resolve for the ACTIVE project; if its live arrangement is non-trivial (>1 tab or any split), confirm via the existing NSAlert-sheet pattern before replacing; then install the built TabList, merge commands, `rebuildSurfaceNodeView()` + refreshes. `func saveLayoutTemplate()` — `LayoutTemplate.capture` from the active project → merge into its `ProjectFile` (preserving other fields) → `ProjectFileIO.save`.
- [ ] Wire `apply-layout` / `save-layout` as `BindingCommand`s + palette entries (follow how existing commands like copy-mode are registered — match the enum's parse/display pattern exactly).
- [ ] Build + `swift test` green. CLI e2e in Task 9.

### Task 6 (v2b sheet): layout-template row

**Files:** modify `App/Sources/App/ProjectSettingsSheet.swift`, `App/Sources/App/AppDelegate.swift` (present call gains template status + save/clear callbacks).

- [ ] Add a "Layout" row after Icon: a status label — "None" / "From repo file (N tabs)" — plus two buttons: **Save Current** (captures the live arrangement into `.zetty/project.json`, via a callback into TVC's `saveLayoutTemplate`) and **Clear** (removes `layoutTemplate` from the project file, preserving other fields; disabled when none). No template editing UI — the JSON is the editor.
- [ ] Build.

### Task 7 (v3 core): per-project env in settings + envNames in repo file

**Files:** modify `Sources/ZettyCore/Settings/ProjectSettings.swift`, `ProjectSettingsResolver.swift`; tests in the existing settings/resolver test files.

**Interfaces:** `ProjectSettings.env: [String: String]?` (private store only); `ResolvedProjectSettings.env: [String: String]` (empty when unset — values never come from the repo file; `envNames` is only documentation shown in the sheet).

- [ ] Failing tests: round-trip with env; `isEmpty` false with only env; resolver returns `[:]` for nil and the map when set.
- [ ] Implement + `swift test` green.

### Task 8 (v3 app): env injection + sheet editor

**Files:** modify `App/Sources/ZettyGhostty/SurfaceRegistry.swift` (`pair(for:)` merge ~line 300), `App/Sources/App/TerminalViewController.swift` (plumb like `sessionCommandProvider`), `App/Sources/App/AppDelegate.swift` (provider), `App/Sources/App/ProjectSettingsSheet.swift` (editor).

**Steps:**
- [ ] Registry: `public var surfaceEnvironment: ((Surface) -> [String: String]?)?`; in the merge, for each pair (sorted by key for determinism): `config = config.custom("env", "\(key)=\(value)")` — the mechanism verified live (ghostty `env` directive reaches the pane's shell, including inside zmx sessions).
- [ ] TVC `var surfaceEnvironmentProvider: ((UUID) -> [String: String]?)?` with a `didSet` adapter mirroring `sessionCommandProvider`; AppDelegate provides via `workspace.project(containing:)` → `resolvedSettings(for:).env`.
- [ ] Sheet: "Environment" row — a small monospaced `NSTextView` (~4 lines, scrollable) holding `KEY=VALUE` per line; parse on save (skip blank lines; reject lines without `=` or with newline-embedded values by dropping them; keys trimmed). Show declared `envNames` from the repo file as placeholder text when the private map is empty. Values persist to the PRIVATE store only.
- [ ] Document the interaction: a zmx-preserved session captures env at first creation — changed env applies to NEW panes/sessions only (same "new panes only" rule as preserve toggles).
- [ ] Build + `swift test` green.

### Task 9: docs, install, e2e, commits

- [ ] README (features bullet extension), AGENTS.md (extend the per-project settings section: theme override, templates + `.zetty/project.json` + startup-command inject-once rule, env mechanism), CLAUDE.md (one-line extension), design docs' status lines (per-project-settings → v2+v3 shipped; layout-templates → shipped via consolidation).
- [ ] `swift test` + Release build + ditto to /Applications + stamp check.
- [ ] CLI e2e (relaunch technique): (1) theme — set `themeOverride` for a scratch project, activate it via `zetty focus`, Glen confirms the re-theme visually; (2) template — author `.zetty/project.json` with 2 tabs / 3 panes / distinct cwds + `echo TPLMARK-N` commands in a scratch dir, `zetty add-project`, then `zetty status --json` (pane count + cwds) and `zetty capture` (TPLMARK output) prove apply + injection; relaunch → capture shows no duplicate TPLMARK (inject-once); (3) env — private env for scratch project, new pane, `echo $KEY` via send/capture.
- [ ] Commits (after Glen's OK), slices: v2a core+app · v2b core · v2b app+sheet · v3 · docs.
