import AppKit
import ZettyGhostty

/// The per-project settings sheet (sidebar → Project Settings…). Programmatic
/// AppKit styled with ZTheme, following SettingsWindowController's idiom.
/// Purely an editor: reads a `ProjectSettings`, hands the edited copy to
/// `onSave` — persistence and re-application live in AppDelegate.
final class ProjectSettingsSheet: NSObject {

    /// Keeps the active sheet (controls + closures) alive until it ends.
    private static var active: ProjectSettingsSheet?

    private let panel: NSWindow
    private let hostWindow: NSWindow
    private let onSave: (ProjectSettings) -> Void
    /// What the sheet was opened with. `saveClicked` starts from this rather
    /// than a blank record, so a field this sheet does not render survives a
    /// Save instead of being silently erased. Every field the sheet DOES edit is
    /// reassigned unconditionally below, so seeding changes nothing for those.
    private let initialSettings: ProjectSettings

    private let nameField: NSTextField
    private var swatchButtons: [NSButton] = []
    private var selectedColorID: String?
    private let iconPicker: IconPickerControl
    private let appearancePopup: NSPopUpButton
    private let themeDarkPopup: NSPopUpButton
    private let themeLightPopup: NSPopUpButton
    private let darkChoices: [String]
    private let lightChoices: [String]
    private static let appearanceChoices = ["system", "dark", "light"]
    private let preserveControl: NSSegmentedControl
    private let notifyControl: NSSegmentedControl
    private let autoHibernateControl: NSSegmentedControl
    private let broadcastPopup: NSPopUpButton
    private static let broadcastScopes: [BroadcastScope] = [.off, .currentTab, .project, .agents, .workspace]
    private static let broadcastLabels = ["Off", "Tab", "Project", "Agents", "Workspace"]
    private let envTextView = NSTextView()

    /// Account choices, parallel to `accountPopup`'s items after the leading
    /// "Default" row. Empty when no accounts are configured, in which case the
    /// row is hidden entirely rather than shown as a useless one-item popup.
    private let accountPopup = NSPopUpButton()
    private let accountChoices: [AgentAccount]

    /// Home's working directory, unique to Home: every other project is rooted
    /// where it was added. nil hides the row entirely.
    private var homeDirectory: String?
    /// What the row opened with, so an untouched Save doesn't rewrite the config.
    private let initialHomeDirectory: String?
    private let homeDirectoryLabel = NSTextField(labelWithString: "")
    private let onSaveHomeDirectory: ((String) -> Void)?

    // Master switch: show the new-pane agent chooser at all.
    private let agentPromptCheck = NSButton(
        checkboxWithTitle: "Ask which agent to launch on new tabs and splits",
        target: nil, action: nil)
    // One checkbox + one command field per SpawnableAgent.catalog entry
    // (parallel arrays, same order as the catalog).
    private var agentChecks: [NSButton] = []
    private var agentCommandFields: [NSTextField] = []

    static func present(
        for projectName: String,
        current: ProjectSettings,
        fallbackName: String,
        layoutStatus: @escaping () -> String,
        onSaveLayout: @escaping () -> Void,
        onApplyLayout: @escaping () -> Void,
        onClearLayout: @escaping () -> Void,
        on window: NSWindow,
        initialTab: String? = nil,
        homeDirectory: String? = nil,
        accounts: [AgentAccount] = [],
        onSaveHomeDirectory: ((String) -> Void)? = nil,
        onSave: @escaping (ProjectSettings) -> Void
    ) {
        let sheet = ProjectSettingsSheet(
            projectName: projectName, current: current, fallbackName: fallbackName,
            layoutStatus: layoutStatus, onSaveLayout: onSaveLayout,
            onApplyLayout: onApplyLayout, onClearLayout: onClearLayout,
            window: window, initialTab: initialTab, homeDirectory: homeDirectory,
            accounts: accounts,
            onSaveHomeDirectory: onSaveHomeDirectory, onSave: onSave)
        active = sheet
        window.beginSheet(sheet.panel)
    }

    private let layoutStatus: () -> String
    private let onSaveLayout: () -> Void
    private let onApplyLayout: () -> Void
    private let onClearLayout: () -> Void
    private let layoutStatusLabel = NSTextField(labelWithString: "")
    private let initialTab: String?

    private init(
        projectName: String,
        current: ProjectSettings,
        fallbackName: String,
        layoutStatus: @escaping () -> String,
        onSaveLayout: @escaping () -> Void,
        onApplyLayout: @escaping () -> Void,
        onClearLayout: @escaping () -> Void,
        window: NSWindow,
        initialTab: String?,
        homeDirectory: String?,
        accounts: [AgentAccount],
        onSaveHomeDirectory: ((String) -> Void)?,
        onSave: @escaping (ProjectSettings) -> Void
    ) {
        self.accountChoices = accounts
        self.hostWindow = window
        self.homeDirectory = homeDirectory
        self.initialHomeDirectory = homeDirectory
        self.onSaveHomeDirectory = onSaveHomeDirectory
        self.layoutStatus = layoutStatus
        self.onSaveLayout = onSaveLayout
        self.onApplyLayout = onApplyLayout
        self.onClearLayout = onClearLayout
        self.initialTab = initialTab
        self.onSave = onSave
        self.initialSettings = current

        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 0),
            styleMask: [.titled],
            backing: .buffered, defer: false)
        panel.title = "Project Settings — \(projectName)"
        panel.appearance = ZTheme.current.appearance
        panel.backgroundColor = ZTheme.current.bg1Color

        nameField = NSTextField(string: current.name ?? "")
        nameField.placeholderString = fallbackName
        nameField.font = ZTheme.chromeFont(size: 13)

        selectedColorID = current.color

        iconPicker = IconPickerControl(selected: current.icon)

        // Appearance + theme overrides, modeled on the global keys: an
        // appearance axis plus a scheme per axis, each independently
        // "Follow Global".
        func schemePopup(choices: [String], selected: String?) -> NSPopUpButton {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItem(withTitle: "Follow Global")
            for name in choices { popup.addItem(withTitle: name) }
            if let selected, let index = choices.firstIndex(of: selected) {
                popup.selectItem(at: index + 1)
            }
            return popup
        }
        darkChoices = ZColorScheme.darkSchemes.map(\.displayName)
        lightChoices = ZColorScheme.lightSchemes.map(\.displayName)
        themeDarkPopup = schemePopup(choices: darkChoices, selected: current.themeDarkOverride)
        themeLightPopup = schemePopup(choices: lightChoices, selected: current.themeLightOverride)

        appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        appearancePopup.addItem(withTitle: "Follow Global")
        for mode in Self.appearanceChoices {
            appearancePopup.addItem(withTitle: mode.capitalized)
        }
        if let mode = current.appearanceOverride,
           let index = Self.appearanceChoices.firstIndex(of: mode) {
            appearancePopup.selectItem(at: index + 1)
        }

        func triState(_ value: Bool?) -> NSSegmentedControl {
            let control = NSSegmentedControl(
                labels: ["Follow Global", "On", "Off"],
                trackingMode: .selectOne, target: nil, action: nil)
            control.selectedSegment = value == nil ? 0 : (value == true ? 1 : 2)
            return control
        }
        preserveControl = triState(current.preserveSessionsOverride)
        notifyControl = triState(current.notificationsOverride)
        autoHibernateControl = triState(current.autoHibernate)

        broadcastPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for label in Self.broadcastLabels { broadcastPopup.addItem(withTitle: label) }
        if let index = Self.broadcastScopes.firstIndex(of: BroadcastScope(code: current.broadcastScope)) {
            broadcastPopup.selectItem(at: index)
        }

        // Item 0 is the agent's own default login — always offered, never
        // stored (nil is what "Default" means on disk).
        accountPopup.addItem(withTitle: "Default")
        for account in accounts { accountPopup.addItem(withTitle: account.name) }
        if let stored = current.accountID,
           let index = accounts.firstIndex(where: { $0.id == stored }) {
            accountPopup.selectItem(at: index + 1)
        } else {
            accountPopup.selectItem(at: 0)
        }

        super.init()
        configureEnvEditor(current: current.env)
        configureAgentControls(current: current.agents, promptOn: current.promptAgentOnNewPane != false)
        buildLayout()
    }

    /// Builds one checkbox + command field per catalog agent, prefilled from
    /// the project's stored `agents` (enabled = present; blank command → the
    /// catalog default, shown but disabled until the checkbox is on).
    private func configureAgentControls(current: [ProjectAgent]?, promptOn: Bool) {
        agentPromptCheck.state = promptOn ? .on : .off
        agentPromptCheck.target = self
        agentPromptCheck.action = #selector(agentPromptToggled(_:))
        var commandByID: [String: String] = [:]
        for entry in current ?? [] where commandByID[entry.id] == nil {
            commandByID[entry.id] = entry.command
        }
        for agent in SpawnableAgent.catalog {
            let check = NSButton(checkboxWithTitle: agent.displayName,
                                 target: self, action: #selector(agentCheckToggled(_:)))
            let stored = commandByID[agent.id]
            check.state = stored != nil ? .on : .off
            check.isEnabled = promptOn
            let field = NSTextField(string: (stored?.isEmpty == false) ? stored! : agent.defaultCommand)
            field.placeholderString = agent.defaultCommand
            field.font = ZTheme.chromeFont(size: 12)
            field.isEnabled = promptOn && stored != nil
            agentChecks.append(check)
            agentCommandFields.append(field)
        }
    }

    /// The master toggle enables/disables all agent rows. When off, the whole
    /// list is greyed out (but the stored selections are preserved).
    @objc private func agentPromptToggled(_ sender: NSButton) {
        updateAgentRowsEnabled()
    }

    private func updateAgentRowsEnabled() {
        let master = agentPromptCheck.state == .on
        for index in agentChecks.indices {
            agentChecks[index].isEnabled = master
            agentCommandFields[index].isEnabled = master && agentChecks[index].state == .on
        }
    }

    @objc private func agentCheckToggled(_ sender: NSButton) {
        guard let index = agentChecks.firstIndex(of: sender) else { return }
        agentCommandFields[index].isEnabled = agentPromptCheck.state == .on && sender.state == .on
    }

    /// Lays out the Agents tab: a caption + one row (checkbox | command) per
    /// catalog agent.
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
        stack.addArrangedSubview(agentPromptCheck)
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

    /// KEY=VALUE per line; values stay in the PRIVATE store only. Parsed on
    /// save — blank lines and lines without `=` are dropped.
    private func configureEnvEditor(current: [String: String]?) {
        envTextView.font = ZTheme.chromeFont(size: 12)
        envTextView.textColor = ZTheme.current.fgColor
        envTextView.backgroundColor = ZTheme.current.bg2Color
        envTextView.isRichText = false
        envTextView.isAutomaticQuoteSubstitutionEnabled = false
        if let env = current, !env.isEmpty {
            envTextView.string = env.keys.sorted()
                .map { "\($0)=\(env[$0]!)" }
                .joined(separator: "\n")
        }
    }

    private func parsedEnv() -> [String: String]? {
        var env: [String: String] = [:]
        for line in envTextView.string.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "="), eq != trimmed.startIndex else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
            guard !key.isEmpty else { continue }
            env[key] = value
        }
        return env.isEmpty ? nil : env
    }

    private func buildLayout() {
        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 6
        let noneSwatch = makeSwatch(color: nil, tooltip: "Default")
        swatchButtons.append(noneSwatch)
        colorRow.addArrangedSubview(noneSwatch)
        for entry in ZTheme.projectPalette {
            // Appearance-reactive: show the variant the sidebar will use.
            let swatch = makeSwatch(color: ZTheme.projectColor(id: entry.id), tooltip: entry.id)
            swatchButtons.append(swatch)
            colorRow.addArrangedSubview(swatch)
        }
        refreshSwatchSelection()

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = ZTheme.chromeFont(size: 13, weight: .medium)
            field.textColor = ZTheme.current.fgColor
            // Row titles never truncate — wide controls squeeze the spacer
            // (or the layout status text) instead.
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            return field
        }
        func row(_ title: String, _ control: NSView) -> NSStackView {
            let stack = NSStackView(views: [label(title), NSView(), control])
            stack.orientation = .horizontal
            return stack
        }

        // Layout template: status + repo-file actions (immediate — they act
        // on .zetty/project.json, independent of the private-store Save).
        layoutStatusLabel.font = ZTheme.chromeFont(size: 11)
        layoutStatusLabel.textColor = ZTheme.current.fg3Color
        layoutStatusLabel.stringValue = layoutStatus()
        layoutStatusLabel.lineBreakMode = .byTruncatingTail
        // The status is the flexible element in its row — it truncates before
        // the row title or the buttons give up any width.
        layoutStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let saveLayoutButton = NSButton(
            title: "Save Current", target: self, action: #selector(saveLayoutClicked))
        let applyLayoutButton = NSButton(
            title: "Apply", target: self, action: #selector(applyLayoutClicked))
        let clearLayoutButton = NSButton(
            title: "Clear", target: self, action: #selector(clearLayoutClicked))
        let layoutControls = NSStackView(views: [
            layoutStatusLabel, NSView(), saveLayoutButton, applyLayoutButton, clearLayoutButton,
        ])
        layoutControls.orientation = .horizontal
        layoutControls.spacing = 6

        // Working directory: Home ONLY. Every other project is rooted where it
        // was added, so the row is absent rather than disabled — it edits the
        // global `zetty-home-path` key, not this project's settings file.
        homeDirectoryLabel.font = ZTheme.chromeFont(size: 11)
        homeDirectoryLabel.textColor = ZTheme.current.fg3Color
        homeDirectoryLabel.lineBreakMode = .byTruncatingHead
        homeDirectoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshHomeDirectoryLabel()
        let chooseHomeButton = NSButton(
            title: "Choose…", target: self, action: #selector(chooseHomeDirectoryClicked))
        let defaultHomeButton = NSButton(
            title: "Use Default", target: self, action: #selector(useDefaultHomeDirectoryClicked))
        let homeDirectoryControls = NSStackView(views: [
            homeDirectoryLabel, NSView(), chooseHomeButton, defaultHomeButton,
        ])
        homeDirectoryControls.orientation = .horizontal
        homeDirectoryControls.spacing = 6

        // General tab: identity + theme + layout + tri-state overrides.
        var generalRows: [NSView] = [
            row("Name", nameField),
            row("Color", colorRow),
            row("Icon", iconPicker),
            row("Appearance", appearancePopup),
            row("Dark Theme", themeDarkPopup),
            row("Light Theme", themeLightPopup),
            row("Layout", layoutControls),
            row("Preserve Sessions", preserveControl),
            row("Auto-hibernate", autoHibernateControl),
            row("Notifications", notifyControl),
            row("Broadcast Input", broadcastPopup),
        ]
        if homeDirectory != nil {
            generalRows.insert(row("Working Directory", homeDirectoryControls), at: 1)
        }
        // Only when accounts exist — a lone "Default" popup would be a control
        // that can't do anything.
        if !accountChoices.isEmpty {
            generalRows.append(row("Account", accountPopup))
        }
        let general = NSStackView(views: generalRows)
        general.orientation = .vertical
        general.spacing = 12
        general.alignment = .leading
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        for case let stack as NSStackView in general.views {
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.widthAnchor.constraint(equalTo: general.widthAnchor).isActive = true
        }

        // Environment tab: KEY=VALUE editor, private store only, new panes only.
        let envScroll = NSScrollView()
        envScroll.documentView = envTextView
        envScroll.hasVerticalScroller = true
        envScroll.drawsBackground = false
        envScroll.translatesAutoresizingMaskIntoConstraints = false
        envScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        envTextView.autoresizingMask = [.width]
        envTextView.minSize = NSSize(width: 0, height: 140)
        envTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                     height: CGFloat.greatestFiniteMagnitude)
        envTextView.isVerticallyResizable = true

        let envCaption = NSTextField(
            wrappingLabelWithString: "One KEY=VALUE per line. Values stay private to this Mac "
                + "(never written into the repo) and apply to new panes only.")
        envCaption.font = ZTheme.chromeFont(size: 11)
        envCaption.textColor = ZTheme.current.fg3Color

        let environment = NSStackView(views: [envScroll, envCaption])
        environment.orientation = .vertical
        environment.spacing = 8
        environment.alignment = .leading
        envScroll.widthAnchor.constraint(equalTo: environment.widthAnchor).isActive = true
        envCaption.translatesAutoresizingMaskIntoConstraints = false
        envCaption.widthAnchor.constraint(equalTo: environment.widthAnchor).isActive = true

        // Tabs (same pattern as SettingsWindowController's window).
        let tabView = NSTabView()
        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = padded(general)
        let environmentItem = NSTabViewItem(identifier: "environment")
        environmentItem.label = "Environment"
        environmentItem.view = padded(environment)
        let agentsItem = NSTabViewItem(identifier: "agents")
        agentsItem.label = "Agents"
        agentsItem.view = padded(buildAgentsTab())
        tabView.addTabViewItem(generalItem)
        tabView.addTabViewItem(agentsItem)
        tabView.addTabViewItem(environmentItem)
        if let initialTab { tabView.selectTabViewItem(withIdentifier: initialTab) }
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.widthAnchor.constraint(equalToConstant: 500).isActive = true

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal

        let root = NSStackView(views: [tabView, buttons])
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: tabView.widthAnchor).isActive = true
        panel.contentView = root
        panel.setContentSize(root.fittingSize)
        panel.initialFirstResponder = nameField
    }

    /// Wraps a tab's content stack with the tab-view item's inner padding.
    private func padded(_ content: NSStackView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func makeSwatch(color: NSColor?, tooltip: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(swatchClicked(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.toolTip = tooltip
        button.layer?.cornerRadius = 9
        button.layer?.borderColor = ZTheme.current.fgColor.cgColor
        button.layer?.backgroundColor = color?.cgColor ?? ZTheme.current.bg3Color.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return button
    }

    private func refreshSwatchSelection() {
        for (index, button) in swatchButtons.enumerated() {
            let id: String? = index == 0 ? nil : ZTheme.projectPalette[index - 1].id
            button.layer?.borderWidth = (id == selectedColorID) ? 2 : 0
        }
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        guard let index = swatchButtons.firstIndex(of: sender) else { return }
        selectedColorID = index == 0 ? nil : ZTheme.projectPalette[index - 1].id
        refreshSwatchSelection()
    }

    private func triStateValue(_ control: NSSegmentedControl) -> Bool? {
        switch control.selectedSegment {
        case 1: true
        case 2: false
        default: nil
        }
    }

    @objc private func saveClicked() {
        var edited = initialSettings
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        edited.name = trimmed.isEmpty ? nil : trimmed
        edited.color = selectedColorID
        edited.icon = iconPicker.selectedIcon
        edited.appearanceOverride = appearancePopup.indexOfSelectedItem > 0
            ? Self.appearanceChoices[appearancePopup.indexOfSelectedItem - 1] : nil
        edited.themeDarkOverride = themeDarkPopup.indexOfSelectedItem > 0
            ? darkChoices[themeDarkPopup.indexOfSelectedItem - 1] : nil
        edited.themeLightOverride = themeLightPopup.indexOfSelectedItem > 0
            ? lightChoices[themeLightPopup.indexOfSelectedItem - 1] : nil
        edited.preserveSessionsOverride = triStateValue(preserveControl)
        edited.notificationsOverride = triStateValue(notifyControl)
        edited.autoHibernate = triStateValue(autoHibernateControl)
        edited.broadcastScope = Self.broadcastScopes[broadcastPopup.indexOfSelectedItem].code
        edited.env = parsedEnv()
        // Item 0 ("Default") stores nil — the absence of an override IS the
        // default login, so there is nothing to write for it.
        let accountIndex = accountPopup.indexOfSelectedItem - 1
        edited.accountID = accountChoices.indices.contains(accountIndex)
            ? accountChoices[accountIndex].id : nil
        var agents: [ProjectAgent] = []
        for (index, agent) in SpawnableAgent.catalog.enumerated() where agentChecks[index].state == .on {
            let typed = agentCommandFields[index].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            agents.append(ProjectAgent(id: agent.id, command: typed.isEmpty ? agent.defaultCommand : typed))
        }
        edited.agents = agents.isEmpty ? nil : agents
        // Checked (default) → nil (follow default = on); unchecked → false.
        edited.promptAgentOnNewPane = agentPromptCheck.state == .on ? nil : false
        hostWindow.endSheet(panel)
        Self.active = nil
        // Home's working directory rides a second channel: it's a global config
        // key, not part of this project's settings file. Only on a real change —
        // persisting it re-renders the whole config file, which an untouched
        // Save has no business doing.
        if let homeDirectory, homeDirectory != initialHomeDirectory {
            onSaveHomeDirectory?(homeDirectory)
        }
        onSave(edited)
    }

    /// Shows the chosen directory tilde-abbreviated — the same form the config
    /// stores, so the row reads like the file it writes.
    private func refreshHomeDirectoryLabel() {
        guard let homeDirectory else { return }
        homeDirectoryLabel.stringValue = (homeDirectory as NSString).abbreviatingWithTildeInPath
    }

    @objc private func chooseHomeDirectoryClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true   // "New Folder", as in the add-project picker
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose or create the directory new Home tabs and panes open in"
        if let homeDirectory { panel.directoryURL = URL(fileURLWithPath: homeDirectory) }
        panel.beginSheetModal(for: self.panel) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.homeDirectory = path
            self?.refreshHomeDirectoryLabel()
        }
    }

    @objc private func useDefaultHomeDirectoryClicked() {
        homeDirectory = NSHomeDirectory()
        refreshHomeDirectoryLabel()
    }

    @objc private func cancelClicked() {
        hostWindow.endSheet(panel)
        Self.active = nil
    }

    @objc private func saveLayoutClicked() {
        onSaveLayout()
        layoutStatusLabel.stringValue = layoutStatus()
    }

    @objc private func applyLayoutClicked() {
        onApplyLayout()
    }

    @objc private func clearLayoutClicked() {
        onClearLayout()
        layoutStatusLabel.stringValue = layoutStatus()
    }
}
