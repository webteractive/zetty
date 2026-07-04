import AppKit
import ZettyCore

/// The per-project settings sheet (sidebar → Project Settings…). Programmatic
/// AppKit styled with ZTheme, following SettingsWindowController's idiom.
/// Purely an editor: reads a `ProjectSettings`, hands the edited copy to
/// `onSave` — persistence and re-application live in AppDelegate.
final class ProjectSettingsSheet: NSObject {

    /// Curated SF Symbols offered as project icons (plus "Default").
    static let iconChoices: [String] = [
        "folder", "terminal", "hammer", "wrench.and.screwdriver", "globe",
        "server.rack", "shippingbox", "book", "flask", "bolt",
    ]

    /// Keeps the active sheet (controls + closures) alive until it ends.
    private static var active: ProjectSettingsSheet?

    private let panel: NSWindow
    private let hostWindow: NSWindow
    private let onSave: (ProjectSettings) -> Void

    private let nameField: NSTextField
    private var swatchButtons: [NSButton] = []
    private var selectedColorID: String?
    private let iconPopup: NSPopUpButton
    private let appearancePopup: NSPopUpButton
    private let themeDarkPopup: NSPopUpButton
    private let themeLightPopup: NSPopUpButton
    private let darkChoices: [String]
    private let lightChoices: [String]
    private static let appearanceChoices = ["system", "dark", "light"]
    private let preserveControl: NSSegmentedControl
    private let notifyControl: NSSegmentedControl
    private let envTextView = NSTextView()

    static func present(
        for projectName: String,
        current: ProjectSettings,
        fallbackName: String,
        layoutStatus: @escaping () -> String,
        onSaveLayout: @escaping () -> Void,
        onApplyLayout: @escaping () -> Void,
        onClearLayout: @escaping () -> Void,
        on window: NSWindow,
        onSave: @escaping (ProjectSettings) -> Void
    ) {
        let sheet = ProjectSettingsSheet(
            projectName: projectName, current: current, fallbackName: fallbackName,
            layoutStatus: layoutStatus, onSaveLayout: onSaveLayout,
            onApplyLayout: onApplyLayout, onClearLayout: onClearLayout,
            window: window, onSave: onSave)
        active = sheet
        window.beginSheet(sheet.panel)
    }

    private let layoutStatus: () -> String
    private let onSaveLayout: () -> Void
    private let onApplyLayout: () -> Void
    private let onClearLayout: () -> Void
    private let layoutStatusLabel = NSTextField(labelWithString: "")

    private init(
        projectName: String,
        current: ProjectSettings,
        fallbackName: String,
        layoutStatus: @escaping () -> String,
        onSaveLayout: @escaping () -> Void,
        onApplyLayout: @escaping () -> Void,
        onClearLayout: @escaping () -> Void,
        window: NSWindow,
        onSave: @escaping (ProjectSettings) -> Void
    ) {
        self.hostWindow = window
        self.layoutStatus = layoutStatus
        self.onSaveLayout = onSaveLayout
        self.onApplyLayout = onApplyLayout
        self.onClearLayout = onClearLayout
        self.onSave = onSave

        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 0),
            styleMask: [.titled],
            backing: .buffered, defer: false)
        panel.title = "Project Settings — \(projectName)"
        panel.appearance = ZTheme.current.appearance
        panel.backgroundColor = ZTheme.current.bg1Color

        nameField = NSTextField(string: current.name ?? "")
        nameField.placeholderString = fallbackName
        nameField.font = ZTheme.monoFont(size: 13)

        selectedColorID = current.color

        iconPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        iconPopup.addItem(withTitle: "Default")
        for symbol in Self.iconChoices {
            iconPopup.addItem(withTitle: symbol)
            iconPopup.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        }
        if let icon = current.icon, let index = Self.iconChoices.firstIndex(of: icon) {
            iconPopup.selectItem(at: index + 1)
        }

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

        super.init()
        configureEnvEditor(current: current.env)
        buildLayout()
    }

    /// KEY=VALUE per line; values stay in the PRIVATE store only. Parsed on
    /// save — blank lines and lines without `=` are dropped.
    private func configureEnvEditor(current: [String: String]?) {
        envTextView.font = ZTheme.monoFont(size: 12)
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
            field.font = ZTheme.monoFont(size: 13, weight: .medium)
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
        layoutStatusLabel.font = ZTheme.monoFont(size: 11)
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

        // General tab: identity + theme + layout + tri-state overrides.
        let general = NSStackView(views: [
            row("Name", nameField),
            row("Color", colorRow),
            row("Icon", iconPopup),
            row("Appearance", appearancePopup),
            row("Dark Theme", themeDarkPopup),
            row("Light Theme", themeLightPopup),
            row("Layout", layoutControls),
            row("Preserve Sessions", preserveControl),
            row("Notifications", notifyControl),
        ])
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
        envCaption.font = ZTheme.monoFont(size: 11)
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
        tabView.addTabViewItem(generalItem)
        tabView.addTabViewItem(environmentItem)
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
        var edited = ProjectSettings()
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        edited.name = trimmed.isEmpty ? nil : trimmed
        edited.color = selectedColorID
        edited.icon = iconPopup.indexOfSelectedItem > 0
            ? Self.iconChoices[iconPopup.indexOfSelectedItem - 1] : nil
        edited.appearanceOverride = appearancePopup.indexOfSelectedItem > 0
            ? Self.appearanceChoices[appearancePopup.indexOfSelectedItem - 1] : nil
        edited.themeDarkOverride = themeDarkPopup.indexOfSelectedItem > 0
            ? darkChoices[themeDarkPopup.indexOfSelectedItem - 1] : nil
        edited.themeLightOverride = themeLightPopup.indexOfSelectedItem > 0
            ? lightChoices[themeLightPopup.indexOfSelectedItem - 1] : nil
        edited.preserveSessionsOverride = triStateValue(preserveControl)
        edited.notificationsOverride = triStateValue(notifyControl)
        edited.env = parsedEnv()
        hostWindow.endSheet(panel)
        Self.active = nil
        onSave(edited)
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
