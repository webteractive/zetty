# Agents Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** [`docs/plans/2026-07-06-agents-tab-design.md`](../../plans/2026-07-06-agents-tab-design.md) — source of truth for *what/why*.

**Goal:** Add an Agents tab to per-project Settings that lists spawnable agents (toggle + editable command); when a project has ≥1 enabled, an interactively-created tab/pane shows an inline overlay to launch one of them or a normal shell.

**Architecture:** A pure `SpawnableAgent` catalog + resolver in `ZettyCore`, independent of `AgentKind`. `ProjectSettings` gains an `agents: [ProjectAgent]?` field (private store). The sheet gets an Agents tab. Interactive spawns mark the new surface as pending-agent-choice; `SurfaceNodeView`/`LeafContainerView` renders an overlay for pending surfaces; choosing injects `command\r` via `registry.sendText`.

**Tech Stack:** Swift, AppKit (App target), swift-testing (`import Testing`) for `ZettyCore`, Tuist-generated Xcode project.

## Global Constraints

- **Keep `ZettyCore` pure** — no AppKit in `Sources/ZettyCore/**`.
- **Never hardcode a color** — overlay/tab chrome reads `ZTheme.current.<token>Color`; standard controls use the system font, terminal-adjacent text may use `ZTheme.monoFont`.
- **No debug `NSLog`/`print`** in committed code.
- **Commits require Glen's approval** — each "Commit" step means stage + ask.
- **New source file** (`SpawnableAgent.swift`) → run `mise exec -- tuist generate --no-open` before the first build/test that compiles it; if a bogus "Manifest not found …/AgentLogos" error appears, run `mise exec -- tuist clean` first.
- **Run core tests** with `swift test` (ZettyCore is a pure SPM package; `swift test --list-tests` to confirm registration). Build the app with `xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build`.
- **Catalog (v1), exact ids/commands:** `claude`→`claude`, `codex`→`codex`, `hermes`→`hermes`, `gemini`→`gemini`, `opencode`→`opencode`, `pi`→`pi`, `cursor`→`cursor-agent`.
- **Triggers:** interactive `newTab(_:)`, `splitVertical`, `splitHorizontal` only. Not CLI `openNewTab`/`splitPane`, not break-pane, not template-command panes, not restored panes.

---

### Task 1: `SpawnableAgent` catalog + `ProjectAgent` + resolver (pure core)

**Files:**
- Create: `Sources/ZettyCore/Agents/SpawnableAgent.swift`
- Test: `Tests/ZettyCoreTests/SpawnableAgentTests.swift`

**Interfaces:**
- Produces:
  - `public struct ProjectAgent: Codable, Sendable, Equatable { public var id: String; public var command: String; public init(id:command:) }`
  - `public struct SpawnableAgent: Sendable, Equatable { public let id, displayName, defaultCommand: String; public init(...) }` with `static let catalog: [SpawnableAgent]` (7 entries) and `static func byID(_:) -> SpawnableAgent?`.
  - `public struct ResolvedSpawnAgent: Sendable, Equatable { public let agent: SpawnableAgent; public let command: String }`
  - `public static func SpawnableAgent.resolve(_ agents: [ProjectAgent]?) -> [ResolvedSpawnAgent]`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ZettyCoreTests/SpawnableAgentTests.swift
import Testing
@testable import ZettyCore

@Test func catalogHasExpectedAgentsAndCommands() {
    let ids = SpawnableAgent.catalog.map(\.id)
    #expect(ids == ["claude", "codex", "hermes", "gemini", "opencode", "pi", "cursor"])
    #expect(SpawnableAgent.byID("cursor")?.defaultCommand == "cursor-agent")
    #expect(SpawnableAgent.byID("claude")?.defaultCommand == "claude")
    #expect(SpawnableAgent.byID("nope") == nil)
}

@Test func resolveDropsUnknownKeepsCatalogOrderAndOverrides() {
    let stored = [
        ProjectAgent(id: "cursor", command: ""),          // blank → default
        ProjectAgent(id: "claude", command: "claude --resume"),
        ProjectAgent(id: "ghost", command: "boo"),        // unknown → dropped
    ]
    let resolved = SpawnableAgent.resolve(stored)
    // Catalog order: claude before cursor; ghost dropped.
    #expect(resolved.map(\.agent.id) == ["claude", "cursor"])
    #expect(resolved.first { $0.agent.id == "claude" }?.command == "claude --resume")
    #expect(resolved.first { $0.agent.id == "cursor" }?.command == "cursor-agent")
}

@Test func resolveEmptyOrNilIsEmpty() {
    #expect(SpawnableAgent.resolve(nil).isEmpty)
    #expect(SpawnableAgent.resolve([]).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- tuist generate --no-open && swift test --filter SpawnableAgentTests`
Expected: FAIL — `SpawnableAgent` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ZettyCore/Agents/SpawnableAgent.swift
import Foundation

/// A per-project enabled agent + its launch command. Presence in
/// `ProjectSettings.agents` means "enabled".
public struct ProjectAgent: Codable, Sendable, Equatable {
    public var id: String
    public var command: String
    public init(id: String, command: String) {
        self.id = id
        self.command = command
    }
}

/// An agent/harness Zetty can launch in a fresh pane. Independent of
/// `AgentKind` (which drives detection): this catalog is purely about spawning.
public struct SpawnableAgent: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let defaultCommand: String

    public init(id: String, displayName: String, defaultCommand: String) {
        self.id = id
        self.displayName = displayName
        self.defaultCommand = defaultCommand
    }

    public static let catalog: [SpawnableAgent] = [
        .init(id: "claude",   displayName: "Claude Code",  defaultCommand: "claude"),
        .init(id: "codex",    displayName: "Codex",        defaultCommand: "codex"),
        .init(id: "hermes",   displayName: "Hermes",       defaultCommand: "hermes"),
        .init(id: "gemini",   displayName: "Gemini",       defaultCommand: "gemini"),
        .init(id: "opencode", displayName: "opencode",     defaultCommand: "opencode"),
        .init(id: "pi",       displayName: "Pi",           defaultCommand: "pi"),
        .init(id: "cursor",   displayName: "Cursor Agent", defaultCommand: "cursor-agent"),
    ]

    public static func byID(_ id: String) -> SpawnableAgent? {
        catalog.first { $0.id == id }
    }

    /// Effective enabled agents: each stored `ProjectAgent` whose id is in the
    /// catalog, paired with its command (stored command, or the catalog default
    /// when blank). Catalog order is preserved; unknown ids are dropped.
    public static func resolve(_ agents: [ProjectAgent]?) -> [ResolvedSpawnAgent] {
        guard let agents, !agents.isEmpty else { return [] }
        var commandByID: [String: String] = [:]
        for entry in agents where commandByID[entry.id] == nil {
            commandByID[entry.id] = entry.command
        }
        return catalog.compactMap { agent in
            guard let raw = commandByID[agent.id] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return ResolvedSpawnAgent(agent: agent, command: trimmed.isEmpty ? agent.defaultCommand : trimmed)
        }
    }
}

/// A catalog agent resolved with the command to actually run.
public struct ResolvedSpawnAgent: Sendable, Equatable {
    public let agent: SpawnableAgent
    public let command: String
    public init(agent: SpawnableAgent, command: String) {
        self.agent = agent
        self.command = command
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpawnableAgentTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Agents/SpawnableAgent.swift Tests/ZettyCoreTests/SpawnableAgentTests.swift
git commit -m "feat(core): SpawnableAgent catalog + ProjectAgent + resolver"
```

---

### Task 2: `ProjectSettings.agents` field

**Files:**
- Modify: `Sources/ZettyCore/Settings/ProjectSettings.swift` (property, init param, `init(from:)` decode)
- Test: `Tests/ZettyCoreTests/ProjectSettingsTests.swift`

**Interfaces:**
- Consumes: `ProjectAgent` (Task 1).
- Produces: `ProjectSettings.agents: [ProjectAgent]?`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ZettyCoreTests/ProjectSettingsTests.swift`:

```swift
@Test func projectSettingsRoundTripsAgents() throws {
    var s = ProjectSettings()
    s.agents = [ProjectAgent(id: "claude", command: "claude"),
                ProjectAgent(id: "cursor", command: "cursor-agent")]
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(ProjectSettings.self, from: data)
    #expect(decoded.agents == s.agents)
    #expect(!s.isEmpty)
}

@Test func projectSettingsAgentsNilStaysEmpty() {
    #expect(ProjectSettings().agents == nil)
    #expect(ProjectSettings().isEmpty)
}

@Test func projectSettingsTolerantDecodeWithoutAgents() throws {
    // A file written before this field existed decodes with agents == nil.
    let json = #"{"name":"X"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ProjectSettings.self, from: json)
    #expect(decoded.name == "X")
    #expect(decoded.agents == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProjectSettingsTests`
Expected: FAIL — `agents` is not a member of `ProjectSettings`.

- [ ] **Step 3: Write minimal implementation**

In `ProjectSettings.swift`, add the property after `env` (before the `init`):

```swift
    /// Per-project spawnable agents (Agents tab). nil/empty → feature off.
    /// Presence of an entry = that agent is enabled; `command` is its launch
    /// command. Stored in the private store only.
    public var agents: [ProjectAgent]?
```

Add the init parameter (after `env: [String: String]? = nil`):

```swift
        env: [String: String]? = nil,
        agents: [ProjectAgent]? = nil
```

Assign it in the init body (after `self.env = env`):

```swift
        self.agents = agents
```

Add to `init(from:)` (after the `env` decode line):

```swift
        agents = try c.decodeIfPresent([ProjectAgent].self, forKey: .agents)
```

(Swift synthesizes `CodingKeys` from stored properties, so `agents` is covered automatically for both keys and the synthesized `encode(to:)`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProjectSettingsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Settings/ProjectSettings.swift Tests/ZettyCoreTests/ProjectSettingsTests.swift
git commit -m "feat(core): ProjectSettings.agents field"
```

---

### Task 3: Agents tab in the Project Settings sheet

**Files:**
- Modify: `App/Sources/App/ProjectSettingsSheet.swift` (new stored controls in init; build the Agents tab; add tab item; save wiring)

**Interfaces:**
- Consumes: `SpawnableAgent.catalog`, `ProjectAgent` (Task 1), `ProjectSettings.agents` (Task 2).
- Produces: the sheet now reads/writes `edited.agents`.

- [ ] **Step 1: Add stored controls + build them in `init`**

Add properties near the other control declarations (after `private let envTextView = NSTextView()`):

```swift
    // One checkbox + one command field per SpawnableAgent.catalog entry
    // (parallel arrays, same order as the catalog).
    private var agentChecks: [NSButton] = []
    private var agentCommandFields: [NSTextField] = []
```

At the end of `init` (after the existing control setup, before/around where other fields are finalized — anywhere in `init` after `super.init` is called; place it just before the setup/layout call), build the rows from the catalog + `current.agents`:

```swift
        // Agents tab controls: prefill from current.agents (id → command).
        let enabledByID: [String: String] = {
            var map: [String: String] = [:]
            for entry in current.agents ?? [] where map[entry.id] == nil { map[entry.id] = entry.command }
            return map
        }()
        for agent in SpawnableAgent.catalog {
            let check = NSButton(checkboxWithTitle: agent.displayName,
                                 target: self, action: #selector(agentCheckToggled(_:)))
            let enabled = enabledByID[agent.id] != nil
            check.state = enabled ? .on : .off
            let field = NSTextField(string: enabledByID[agent.id]?.isEmpty == false
                                    ? enabledByID[agent.id]! : agent.defaultCommand)
            field.placeholderString = agent.defaultCommand
            field.font = ZTheme.monoFont(size: 12)
            field.isEnabled = enabled
            agentChecks.append(check)
            agentCommandFields.append(field)
        }
```

> Note: if `current` isn't available where you place this (it's an `init` parameter), keep it in `init` where `current` is in scope. The controls are stored, so the layout method can lay them out later.

- [ ] **Step 2: Build the Agents tab view + add the tab item**

Add a helper that lays out the rows (near `padded(_:)`):

```swift
    private func buildAgentsTab() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let caption = NSTextField(labelWithString:
            "Enabled agents can be launched when you open a new tab or split in this project.")
        caption.textColor = ZTheme.current.fg3Color
        caption.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(caption)
        for index in SpawnableAgent.catalog.indices {
            let row = NSStackView(views: [agentChecks[index], agentCommandFields[index]])
            row.orientation = .horizontal
            row.spacing = 8
            agentChecks[index].translatesAutoresizingMaskIntoConstraints = false
            agentChecks[index].widthAnchor.constraint(equalToConstant: 150).isActive = true
            agentCommandFields[index].translatesAutoresizingMaskIntoConstraints = false
            agentCommandFields[index].widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
            stack.addArrangedSubview(row)
        }
        return stack
    }

    @objc private func agentCheckToggled(_ sender: NSButton) {
        guard let index = agentChecks.firstIndex(of: sender) else { return }
        agentCommandFields[index].isEnabled = sender.state == .on
    }
```

In the tab-building section (where `generalItem`/`environmentItem` are created, ~line 276), add:

```swift
        let agentsItem = NSTabViewItem(identifier: "agents")
        agentsItem.label = "Agents"
        agentsItem.view = padded(buildAgentsTab())
        tabView.addTabViewItem(agentsItem)
```

(add it after `tabView.addTabViewItem(environmentItem)`).

- [ ] **Step 3: Persist on save**

In `saveClicked()`, before `hostWindow.endSheet(panel)`, build `edited.agents`:

```swift
        var agents: [ProjectAgent] = []
        for (index, agent) in SpawnableAgent.catalog.enumerated() where agentChecks[index].state == .on {
            let typed = agentCommandFields[index].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            agents.append(ProjectAgent(id: agent.id, command: typed.isEmpty ? agent.defaultCommand : typed))
        }
        edited.agents = agents.isEmpty ? nil : agents
```

- [ ] **Step 4: Build**

Run: `mise exec -- tuist generate --no-open && xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Verify live + commit**

Install/run; sidebar → Project Settings… → **Agents** tab shows 7 rows; checking one enables its command field; Save then reopen shows the choice persisted (also visible in `~/Library/Application Support/zetty/project-settings.json`). Then:

```bash
git add App/Sources/App/ProjectSettingsSheet.swift
git commit -m "feat(app): Agents tab in project settings (toggle + editable command)"
```

---

### Task 4: Inline chooser overlay + spawn triggers + injection

**Files:**
- Modify: `App/Sources/App/TerminalViewController.swift` (`agentsProvider`, `panesPendingAgentChoice`, `markPendingAgentChoiceIfEnabled`, `chooseAgent`, `dismissAgentChoice`, `newTab(_:)`, `rebuildSurfaceNodeView` call)
- Modify: `App/Sources/App/PaneActions.swift` (`splitVertical`/`splitHorizontal` marking)
- Modify: `App/Sources/App/SurfaceNodeView.swift` (thread choices + build overlay in `LeafContainerView`; add `AgentChooserOverlay`)
- Modify: `App/Sources/App/AppDelegate.swift` (wire `agentsProvider`)

**Interfaces:**
- Consumes: `SpawnableAgent.resolve`, `ResolvedSpawnAgent` (Task 1); `ProjectSettings.agents` via `projectSettings.settings(for:)` (Task 2); `registry.sendText(_:to:)`, `surface(with:)`, `workspace.project(containing:)` (existing).
- Produces: `TerminalViewController.agentsProvider`, `chooseAgent(surfaceID:command:)`, `dismissAgentChoice(surfaceID:)`, `markPendingAgentChoiceIfEnabled(_:)`.

- [ ] **Step 1: Add provider + pending map + mark/choose/dismiss to TVC**

Near the other provider properties in `TerminalViewController` (e.g. by `var projectIdentity`), add:

```swift
    /// Resolves a project's enabled spawnable agents (from per-project settings).
    var agentsProvider: ((ProjectRuntime) -> [ResolvedSpawnAgent])?

    /// Surfaces awaiting the inline agent chooser, mapped to their options.
    private var panesPendingAgentChoice: [UUID: [ResolvedSpawnAgent]] = [:]

    /// Marks a freshly, interactively spawned surface as pending the chooser,
    /// when its project has enabled agents and no template command is queued.
    func markPendingAgentChoiceIfEnabled(_ surfaceID: UUID) {
        guard pendingStartupCommands[surfaceID] == nil,
              let project = workspace.project(containing: surfaceID),
              let agents = agentsProvider?(project), !agents.isEmpty else { return }
        panesPendingAgentChoice[surfaceID] = agents
    }

    /// User picked an agent: inject its command into the (already running) shell.
    func chooseAgent(surfaceID: UUID, command: String) {
        panesPendingAgentChoice.removeValue(forKey: surfaceID)
        if let surface = surface(with: surfaceID) {
            _ = registry.sendText(command + "\r", to: surface)
        }
    }

    /// User dismissed the chooser (Normal shell / Esc): leave the plain shell.
    func dismissAgentChoice(surfaceID: UUID) {
        panesPendingAgentChoice.removeValue(forKey: surfaceID)
    }
```

- [ ] **Step 2: Mark on interactive spawns**

In `TerminalViewController.newTab(_:)`, after `workspace.activeTabList.newTab()`:

```swift
    @objc func newTab(_ sender: Any?) {
        workspace.activeTabList.newTab()
        if let id = workspace.activeTabList.activeTree.focusedSurface?.id {
            markPendingAgentChoiceIfEnabled(id)
        }
        refreshTabBar()
        refreshSidebar()
        rebuildSurfaceNodeView()
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
    }
```

In `PaneActions.swift`, in both split actions, after `paneTree.splitFocused(...)` and before `rebuildAndFocus()`:

```swift
    @objc func splitVertical(_ sender: Any?) {
        let workingDir = paneTree.focusedSurface?.workingDir ?? NSHomeDirectory()
        let newSurface = Surface(workingDir: workingDir)
        paneTree.splitFocused(direction: .vertical, newSurface: newSurface)
        markPendingAgentChoiceIfEnabled(newSurface.id)
        rebuildAndFocus()
    }

    @objc func splitHorizontal(_ sender: Any?) {
        let workingDir = paneTree.focusedSurface?.workingDir ?? NSHomeDirectory()
        let newSurface = Surface(workingDir: workingDir)
        paneTree.splitFocused(direction: .horizontal, newSurface: newSurface)
        markPendingAgentChoiceIfEnabled(newSurface.id)
        rebuildAndFocus()
    }
```

- [ ] **Step 3: Thread choices into `SurfaceNodeView` + build the overlay**

In `SurfaceNodeView.swift`, extend `init` and `buildContent` to carry the pending map + callbacks. Add these params (with defaults) to **both** `init` and `buildContent`:

```swift
        agentChoices: [UUID: [ResolvedSpawnAgent]] = [:],
        onAgentChosen: ((UUID, String) -> Void)? = nil,
        onAgentDismissed: ((UUID) -> Void)? = nil,
```

Pass them through from `init` to `buildContent` (mirror the existing `focusedSurfaceID` threading), and forward them in the recursive split-branch `SurfaceNodeView(...)` calls inside `buildContent`.

In the `.leaf(surface)` branch of `buildContent`, after creating the `LeafContainerView`, pass the leaf's options + callbacks:

```swift
            let container = LeafContainerView(
                surfaceID: surface.id,
                terminalView: terminalView,
                // ...existing args...
                agentChoices: agentChoices[surface.id],
                onAgentChosen: onAgentChosen,
                onAgentDismissed: onAgentDismissed
            )
```

Extend `LeafContainerView.init` with:

```swift
        agentChoices: [ResolvedSpawnAgent]? = nil,
        onAgentChosen: ((UUID, String) -> Void)? = nil,
        onAgentDismissed: ((UUID) -> Void)? = nil,
```

At the end of `LeafContainerView.init` (after the terminalView/status-dot setup), add the overlay when there are options:

```swift
        if let agentChoices, !agentChoices.isEmpty {
            let overlay = AgentChooserOverlay(
                agents: agentChoices,
                onChoose: { [weak self] command in
                    guard let self else { return }
                    self.agentOverlay?.removeFromSuperview()
                    self.agentOverlay = nil
                    onAgentChosen?(self.surfaceID, command)
                },
                onDismiss: { [weak self] in
                    guard let self else { return }
                    self.agentOverlay?.removeFromSuperview()
                    self.agentOverlay = nil
                    onAgentDismissed?(self.surfaceID)
                })
            overlay.translatesAutoresizingMaskIntoConstraints = false
            addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.centerXAnchor.constraint(equalTo: centerXAnchor),
                overlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            agentOverlay = overlay
        }
```

Add the stored ref to `LeafContainerView`:

```swift
    private var agentOverlay: NSView?
```

Add the overlay view class at the bottom of `SurfaceNodeView.swift`:

```swift
/// A small card shown over a fresh pane offering to launch an enabled agent.
/// Non-modal: the terminal stays usable; "Normal shell" (Esc) dismisses.
private final class AgentChooserOverlay: NSView {
    private let onChoose: (String) -> Void
    private let onDismiss: () -> Void
    private var commands: [Int: String] = [:]   // button tag → command

    init(agents: [ResolvedSpawnAgent], onChoose: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.onChoose = onChoose
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = ZTheme.current.bg2Color.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = ZTheme.current.bg3Color.cgColor

        let title = NSTextField(labelWithString: "Launch an agent?")
        title.font = ZTheme.monoFont(size: 13)
        title.textColor = ZTheme.current.accentColor

        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, resolved) in agents.enumerated() {
            let button = NSButton(title: resolved.agent.displayName, target: self,
                                  action: #selector(agentClicked(_:)))
            button.tag = index
            commands[index] = resolved.command
            stack.addArrangedSubview(button)
        }
        let normal = NSButton(title: "Normal shell", target: self, action: #selector(normalClicked(_:)))
        normal.keyEquivalent = "\u{1b}"   // Esc dismisses (window-wide key equivalent)
        stack.addArrangedSubview(normal)

        let hint = NSTextField(labelWithString: "Esc = normal shell")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = ZTheme.current.fg3Color
        stack.addArrangedSubview(hint)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func agentClicked(_ sender: NSButton) {
        guard let command = commands[sender.tag] else { return }
        onChoose(command)
    }

    @objc private func normalClicked(_ sender: NSButton) { onDismiss() }
}
```

- [ ] **Step 4: Pass the map + callbacks from `rebuildSurfaceNodeView`**

In `rebuildSurfaceNodeView()`, extend the `SurfaceNodeView(...)` construction with:

```swift
            agentChoices: panesPendingAgentChoice,
            onAgentChosen: { [weak self] id, command in self?.chooseAgent(surfaceID: id, command: command) },
            onAgentDismissed: { [weak self] id in self?.dismissAgentChoice(surfaceID: id) },
```

- [ ] **Step 5: Wire `agentsProvider` in AppDelegate**

Near the other `tvc.*Provider` assignments (after `tvc.projectIdentity = …`, ~line 148), add:

```swift
        tvc.agentsProvider = { [weak self] project in
            guard let self else { return [] }
            return SpawnableAgent.resolve(self.projectSettings.settings(for: project.rootPath)?.agents)
        }
```

- [ ] **Step 6: Build**

Run: `mise exec -- tuist generate --no-open && xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Verify live + commit**

Install/run. In a project with **no** agents enabled: new tab/split behaves exactly as before (no overlay). Enable Claude + Cursor for a project, then:
- **New tab** → overlay card appears with "Claude Code", "Cursor Agent", "Normal shell".
- Click **Claude Code** → `claude` runs in that pane; overlay gone.
- **Split** → overlay again; **Esc** or **Normal shell** → plain shell.
- **CLI** `zetty new-tab` in that project → no overlay (interactive-only).

Then:

```bash
git add App/Sources/App/TerminalViewController.swift App/Sources/App/PaneActions.swift App/Sources/App/SurfaceNodeView.swift App/Sources/App/AppDelegate.swift
git commit -m "feat(app): inline agent chooser overlay on new interactive panes"
```

---

## Self-Review

**Spec coverage:**
- 7-agent catalog independent of AgentKind → Task 1 ✓
- `ProjectSettings.agents` in private store → Task 2 ✓
- Agents tab: toggle + editable command, defaults, save → Task 3 ✓
- Inline overlay on interactive new-tab/split; inject command; Normal/Esc dismiss → Task 4 ✓
- Triggers exclude CLI/break/template/restore → Task 4 (`markPendingAgentChoiceIfEnabled` only called from interactive `newTab`/split actions; guards on `pendingStartupCommands`) ✓
- Resolver drops unknown ids / preserves order / command fallback → Task 1 ✓
- Tolerant decode / isEmpty semantics → Task 2 ✓

**Deviations (deliberate):** "dismiss on type" from the design is dropped — reliably detecting terminal keystrokes needs a key monitor and would risk eating the first keystroke. Dismissal is **buttons + Esc** (Esc via the Normal-shell button's window-wide key equivalent). Overlay is non-modal, so the pane is never blocked. Detection/logo parity for pi/cursor remains a noted follow-up (spec non-goal).

**Type consistency:** `ProjectAgent(id:command:)`, `SpawnableAgent` (`catalog`/`byID`/`resolve`), `ResolvedSpawnAgent(agent:command:)`, `agentsProvider -> [ResolvedSpawnAgent]`, `panesPendingAgentChoice: [UUID: [ResolvedSpawnAgent]]`, `markPendingAgentChoiceIfEnabled(_:)`, `chooseAgent(surfaceID:command:)`, `dismissAgentChoice(surfaceID:)`, `AgentChooserOverlay(agents:onChoose:onDismiss:)` — consistent across tasks.

**Placeholder scan:** no TBD/TODO; every code step is complete; every command has an expected result.
