import AppKit
import ZettyCore

/// A small themed Settings window. Currently hosts the **Agent Status Hooks**
/// section — a toggle per harness that installs/uninstalls Zetty's status hook.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let installer: HookInstaller
    private var switches: [(harness: Harness, control: NSSwitch)] = []
    private let configURL = ConfigStore().fileURL

    /// Every live surface ID (for orphaned-session diffing).
    private let liveSurfaceIDs: () -> [UUID]

    /// Detected text-capable apps backing the editor dropdown (parallel to its
    /// items after the leading "System Default").
    private let editorPopup = NSPopUpButton()
    private var editorApps: [URL] = []

    // Behavior section controls.
    private let confirmQuitSwitch = NSSwitch()
    private let notifySoundSwitch = NSSwitch()
    private let notifyBadgeSwitch = NSSwitch()
    private let notifySystemSwitch = NSSwitch()

    // Command Line section controls.
    private let cliStatusLabel = NSTextField(labelWithString: "")
    private let cliInstallButton = NSButton(title: "Install CLI", target: nil, action: nil)

    // Sessions section controls.
    private let preserveSwitch = NSSwitch()
    private let sessionStatusLabel = NSTextField(labelWithString: "")
    private let orphanButton = NSButton(title: "", target: nil, action: nil)
    private var orphanSessions: [String] = []

    // Appearance section controls.
    private let appearancePopup = NSPopUpButton()
    private let darkThemePopup = NSPopUpButton()
    private let lightThemePopup = NSPopUpButton()
    private let sidebarPositionPopup = NSPopUpButton()
    private let fontCombo = NSComboBox()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()

    /// Combo item 0 — clears the font-family directive (terminal + chrome
    /// fall back to their defaults, both JetBrains Mono).
    private static let defaultFontItem = "Default (JetBrains Mono)"

    /// Coding fonts offered when installed (the combo also accepts free text —
    /// any family name ghostty accepts).
    private static let curatedFontFamilies = [
        "SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Hack",
        "Source Code Pro", "IBM Plex Mono", "Cascadia Code", "Iosevka", "Geist Mono",
    ]

    /// Font size bounds offered by the stepper (ghostty accepts a float).
    private static let fontSizeRange: ClosedRange<Double> = 8...32

    /// Called when the user picks an appearance mode (owner applies + persists).
    var onSetAppearance: ((AppearanceMode) -> Void)?

    /// Called when the user picks a color scheme (owner applies + persists).
    var onSelectTheme: ((ZColorScheme) -> Void)?

    /// Called when the user picks a sidebar position (owner applies + persists).
    var onSetSidebarPosition: ((SidebarPosition) -> Void)?

    /// Called when the user picks a font family; `nil` → back to default
    /// (owner applies + persists).
    var onSetFontFamily: ((String?) -> Void)?

    /// Called when the user changes the font size; `nil` → back to default
    /// (owner applies + persists).
    var onSetFontSize: ((Float?) -> Void)?

    init(installer: HookInstaller, liveSurfaceIDs: @escaping () -> [UUID] = { [] }) {
        self.installer = installer
        self.liveSurfaceIDs = liveSurfaceIDs
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.appearance = ZTheme.current.appearance
        window.backgroundColor = ZTheme.current.bg1Color
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Refreshes toggle states + the editor selection from disk each time the
    /// window is shown.
    func refresh() {
        for (harness, control) in switches {
            control.state = installer.isInstalled(harness) ? .on : .off
        }
        if editorPopup.numberOfItems > 0 { populateEditorPopup() }
        refreshAppearance()
        refreshCLI()
        refreshSessions()
    }

    // MARK: - Content

    /// The tab view hosting the settings panes (kept for reselect-on-rebuild).
    private var tabView: NSTabView?

    /// The chrome font this window's content was built with. Font commits skip
    /// the mid-interaction rebuild (it flickers and drops focus), so the window
    /// re-fonts here on its next presentation instead.
    private var builtFontStamp = ""
    private static var fontStamp: String { "\(ZTheme.fontFamily ?? "")|\(ZTheme.fontScale)" }

    override func showWindow(_ sender: Any?) {
        if builtFontStamp != Self.fontStamp { rebuildAfterThemeChange() }
        super.showWindow(sender)
    }

    private func buildContent() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = ZTheme.current.bg1Color.cgColor

        builtFontStamp = Self.fontStamp
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tabItem("General", buildGeneralTab()))
        tabs.addTabViewItem(tabItem("Appearance", buildAppearanceTab()))
        tabs.addTabViewItem(tabItem("Sessions", buildSessionsTab()))
        tabs.addTabViewItem(tabItem("Agents", buildAgentsTab()))
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        tabView = tabs
        refresh()
        return root
    }

    private func tabItem(_ label: String, _ content: NSView) -> NSTabViewItem {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14),
        ])
        let item = NSTabViewItem()
        item.label = label
        item.view = container
        return item
    }

    private func sectionStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func addFullWidth(_ row: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: Tabs

    /// General: config file + editor, quit behavior, CLI install.
    private func buildGeneralTab() -> NSView {
        let stack = sectionStack()

        stack.addArrangedSubview(sectionHeader("Configuration"))
        stack.addArrangedSubview(caption(abbreviatedConfigPath()))
        stack.addArrangedSubview(caption(
            "appearance, theme-dark, theme-light and preserve-sessions are Zetty's own keys; "
            + "every other key = value is forwarded verbatim to the terminal, so an existing "
            + "ghostty config can be pasted straight in. Reload anytime with ⇧⌘,."
        ))

        // Editor row: a dropdown of detected text editors + the open button.
        editorPopup.target = self
        editorPopup.action = #selector(editorPicked(_:))
        editorPopup.translatesAutoresizingMaskIntoConstraints = false
        let openButton = NSButton(title: "Open in Editor", target: self, action: #selector(openConfig(_:)))
        openButton.bezelStyle = .rounded
        openButton.translatesAutoresizingMaskIntoConstraints = false
        let editorRow = NSStackView(views: [editorPopup, openButton])
        editorRow.orientation = .horizontal
        editorRow.spacing = 8
        stack.addArrangedSubview(editorRow)
        populateEditorPopup()

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(sectionHeader("Behavior"))
        confirmQuitSwitch.target = self
        confirmQuitSwitch.action = #selector(confirmQuitToggled(_:))
        addFullWidth(switchRow("Confirm before quitting", control: confirmQuitSwitch), to: stack)

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(sectionHeader("Command Line"))
        stack.addArrangedSubview(caption(
            "The zetty CLI drives the app from any terminal or agent: status, "
            + "send keys, open/close/split tabs, capture pane output. "
            + "Installs a symlink at ~/.local/bin/zetty."
        ))
        cliStatusLabel.font = ZTheme.monoFont(size: 11)
        cliStatusLabel.textColor = ZTheme.current.fg3Color
        stack.addArrangedSubview(cliStatusLabel)
        cliInstallButton.bezelStyle = .rounded
        cliInstallButton.target = self
        cliInstallButton.action = #selector(installCLI(_:))
        stack.addArrangedSubview(cliInstallButton)

        return stack
    }

    /// Appearance: mode + per-axis theme pickers.
    private func buildAppearanceTab() -> NSView {
        let stack = sectionStack()
        appearancePopup.removeAllItems()
        appearancePopup.addItems(withTitles: AppearanceMode.allCases.map { $0.rawValue.capitalized })
        appearancePopup.target = self
        appearancePopup.action = #selector(appearancePicked(_:))
        darkThemePopup.removeAllItems()
        darkThemePopup.addItems(withTitles: ZColorScheme.darkSchemes.map(\.displayName))
        darkThemePopup.target = self
        darkThemePopup.action = #selector(darkThemePicked(_:))
        lightThemePopup.removeAllItems()
        lightThemePopup.addItems(withTitles: ZColorScheme.lightSchemes.map(\.displayName))
        lightThemePopup.target = self
        lightThemePopup.action = #selector(lightThemePicked(_:))
        stack.addArrangedSubview(caption(
            "System follows macOS and switches between the dark and light theme live; "
            + "Dark/Light pin one axis."
        ))
        sidebarPositionPopup.removeAllItems()
        sidebarPositionPopup.addItems(withTitles: SidebarPosition.allCases.map { $0.rawValue.capitalized })
        sidebarPositionPopup.target = self
        sidebarPositionPopup.action = #selector(sidebarPositionPicked(_:))
        for (title, popup) in [
            ("Appearance", appearancePopup),
            ("Dark theme", darkThemePopup),
            ("Light theme", lightThemePopup),
            ("Sidebar position", sidebarPositionPopup),
        ] {
            addFullWidth(popupRow(title, popup: popup), to: stack)
        }

        fontCombo.usesDataSource = false
        fontCombo.completes = true
        fontCombo.removeAllItems()
        fontCombo.addItems(withObjectValues: [Self.defaultFontItem] + installedCuratedFonts())
        // NSComboBox only fires target/action on Enter — dropdown selection
        // reports via the delegate (comboBoxSelectionDidChange) and typed text
        // that loses focus via controlTextDidEndEditing. Wire all three.
        fontCombo.delegate = self
        fontCombo.target = self
        fontCombo.action = #selector(fontPicked(_:))
        addFullWidth(controlRow("Font", control: fontCombo, width: 220), to: stack)

        fontSizeField.alignment = .right
        fontSizeField.placeholderString = "13"
        fontSizeField.delegate = self   // commit on focus loss, not just Enter
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeTyped(_:))
        fontSizeStepper.minValue = Self.fontSizeRange.lowerBound
        fontSizeStepper.maxValue = Self.fontSizeRange.upperBound
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepped(_:))
        let sizeGroup = NSStackView(views: [fontSizeField, fontSizeStepper])
        sizeGroup.orientation = .horizontal
        sizeGroup.spacing = 4
        fontSizeField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        addFullWidth(controlRow("Font size", control: sizeGroup, width: 0), to: stack)
        stack.addArrangedSubview(caption(
            "Applies to the terminal and Zetty's chrome together. Any font name "
            + "ghostty accepts can be typed; blank size means the default (13)."
        ))
        return stack
    }

    /// Curated coding fonts filtered to what's actually installed.
    private func installedCuratedFonts() -> [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return Self.curatedFontFamilies.filter(installed.contains)
    }

    /// Sessions: zmx-backed preservation + orphan cleanup.
    private func buildSessionsTab() -> NSView {
        let stack = sectionStack()
        stack.addArrangedSubview(caption(
            "Keep terminal sessions running when Zetty quits, and reattach them on relaunch. Powered by zmx.",
            link: "zmx", url: "https://github.com/neurosnap/zmx"
        ))
        preserveSwitch.target = self
        preserveSwitch.action = #selector(preserveToggled(_:))
        addFullWidth(switchRow("Preserve sessions", control: preserveSwitch), to: stack)

        sessionStatusLabel.font = ZTheme.monoFont(size: 11)
        sessionStatusLabel.textColor = ZTheme.current.fg3Color
        stack.addArrangedSubview(sessionStatusLabel)

        orphanButton.bezelStyle = .rounded
        orphanButton.target = self
        orphanButton.action = #selector(killOrphans(_:))
        orphanButton.isHidden = true
        stack.addArrangedSubview(orphanButton)
        return stack
    }

    /// Agents: attention notifications + per-harness status hooks.
    private func buildAgentsTab() -> NSView {
        let stack = sectionStack()

        stack.addArrangedSubview(sectionHeader("Notifications"))
        stack.addArrangedSubview(caption(
            "When an agent needs attention. The badge shows the attention-pane "
            + "count; macOS notifications fire only while Zetty is in the background."
        ))
        notifySoundSwitch.target = self
        notifySoundSwitch.action = #selector(notifySoundToggled(_:))
        addFullWidth(switchRow("Attention sound", control: notifySoundSwitch), to: stack)
        notifyBadgeSwitch.target = self
        notifyBadgeSwitch.action = #selector(notifyBadgeToggled(_:))
        addFullWidth(switchRow("Dock badge", control: notifyBadgeSwitch), to: stack)
        notifySystemSwitch.target = self
        notifySystemSwitch.action = #selector(notifySystemToggled(_:))
        addFullWidth(switchRow("macOS notifications", control: notifySystemSwitch), to: stack)

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(sectionHeader("Status Hooks"))
        stack.addArrangedSubview(caption(
            "Install a hook so the harness reports agent status to Zetty. "
            + "Status shows as sidebar dots — green running, yellow needs-attention, dim idle."
        ))
        for harness in Harness.allCases {
            let (row, control) = harnessRow(harness)
            switches.append((harness, control))
            addFullWidth(row, to: stack)
        }
        stack.addArrangedSubview(caption("Restart the agent after enabling for the hook to take effect."))
        return stack
    }

    /// A justified label + switch row (same anatomy as the harness rows).
    private func switchRow(_ title: String, control: NSSwitch) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = ZTheme.monoFont(size: 13, weight: .medium)
        label.textColor = ZTheme.current.fgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    /// A justified label + popup row (same anatomy as the switch rows).
    private func popupRow(_ title: String, popup: NSPopUpButton) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = ZTheme.monoFont(size: 13, weight: .medium)
        label.textColor = ZTheme.current.fgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(popup)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            popup.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        return row
    }

    /// A justified label + arbitrary control row (same anatomy as the popup
    /// rows). `width` > 0 pins the control's width.
    private func controlRow(_ title: String, control: NSView, width: CGFloat) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = ZTheme.monoFont(size: 13, weight: .medium)
        label.textColor = ZTheme.current.fgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        var constraints = [
            row.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ]
        if width > 0 {
            constraints.append(control.widthAnchor.constraint(equalToConstant: width))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    // MARK: - Appearance

    /// Syncs the appearance + theme popups with the config on disk.
    private func refreshAppearance() {
        let config = ConfigStore(fileURL: configURL).load()
        if let index = AppearanceMode.allCases.firstIndex(of: config.appearance) {
            appearancePopup.selectItem(at: index)
        }
        let dark = ZColorScheme.named(config.themeDark) ?? .midnight
        if let index = ZColorScheme.darkSchemes.firstIndex(of: dark) {
            darkThemePopup.selectItem(at: index)
        }
        let light = ZColorScheme.named(config.themeLight) ?? .paper
        if let index = ZColorScheme.lightSchemes.firstIndex(of: light) {
            lightThemePopup.selectItem(at: index)
        }
        if let index = SidebarPosition.allCases.firstIndex(of: config.sidebarPosition) {
            sidebarPositionPopup.selectItem(at: index)
        }
        fontCombo.stringValue = config.ghosttyValue("font-family") ?? Self.defaultFontItem
        let size = config.ghosttyValue("font-size").flatMap(Double.init)
        // Locale-independent (no grouping / "," decimals) so the value round-trips
        // through the config file and Double.init.
        fontSizeField.stringValue = size.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
        fontSizeStepper.doubleValue = size ?? Double(ZTheme.defaultFontSize)
    }

    @objc private func appearancePicked(_ sender: NSPopUpButton) {
        let modes = AppearanceMode.allCases
        guard (0..<modes.count).contains(sender.indexOfSelectedItem) else { return }
        onSetAppearance?(modes[sender.indexOfSelectedItem])
        rebuildAfterThemeChange()
    }

    @objc private func darkThemePicked(_ sender: NSPopUpButton) {
        let schemes = ZColorScheme.darkSchemes
        guard (0..<schemes.count).contains(sender.indexOfSelectedItem) else { return }
        onSelectTheme?(schemes[sender.indexOfSelectedItem])
        rebuildAfterThemeChange()
    }

    @objc private func lightThemePicked(_ sender: NSPopUpButton) {
        let schemes = ZColorScheme.lightSchemes
        guard (0..<schemes.count).contains(sender.indexOfSelectedItem) else { return }
        onSelectTheme?(schemes[sender.indexOfSelectedItem])
        rebuildAfterThemeChange()
    }

    @objc private func fontPicked(_ sender: NSComboBox) {
        commitFontFamily(sender.stringValue)
    }

    @objc private func fontSizeTyped(_ sender: NSTextField) {
        commitFontSize(sender.stringValue)
    }

    @objc private func fontSizeStepped(_ sender: NSStepper) {
        let value = sender.doubleValue
        fontSizeField.stringValue = value == value.rounded() ? String(Int(value)) : String(value)
        commitFontSize(fontSizeField.stringValue)
    }

    /// Persists a font-family choice when it differs from the config (the
    /// commit can arrive via action, dropdown delegate, AND focus loss — the
    /// no-op guard keeps the overlap from re-applying). The window content is
    /// deliberately NOT rebuilt here: rebuilding mid-interaction flickers and
    /// drops focus; this window re-fonts on its next open instead.
    private func commitFontFamily(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let family: String? = (value.isEmpty || value == Self.defaultFontItem) ? nil : value
        let current = ConfigStore(fileURL: configURL).load().ghosttyValue("font-family")
        guard family != current else { return }
        onSetFontFamily?(family)
    }

    /// Persists a font-size edit when it differs from the config; unparseable
    /// text reverts to the config's value, blank means default. No rebuild —
    /// see `commitFontFamily`.
    private func commitFontSize(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let current = ConfigStore(fileURL: configURL).load().ghosttyValue("font-size").flatMap(Double.init)
        guard !value.isEmpty else {
            guard current != nil else { return }
            onSetFontSize?(nil)   // blank → default
            return
        }
        guard let size = Double(value) else {
            refreshAppearance()   // unparseable → revert to the config's value
            return
        }
        let clamped = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        guard clamped != current else { return }
        fontSizeStepper.doubleValue = clamped
        onSetFontSize?(Float(clamped))
    }

    @objc private func sidebarPositionPicked(_ sender: NSPopUpButton) {
        let positions = SidebarPosition.allCases
        guard (0..<positions.count).contains(sender.indexOfSelectedItem) else { return }
        onSetSidebarPosition?(positions[sender.indexOfSelectedItem])
    }

    /// Re-themes this window after an appearance/scheme change made from it:
    /// token colors are baked into the labels at build time, so the content is
    /// rebuilt against the new palette (staying on the same tab).
    private func rebuildAfterThemeChange() {
        let selectedIndex = tabView.flatMap { tabs in
            tabs.selectedTabViewItem.map(tabs.indexOfTabViewItem)
        }
        switches.removeAll()
        window?.appearance = ZTheme.current.appearance
        window?.backgroundColor = ZTheme.current.bg1Color
        window?.contentView = buildContent()
        if let selectedIndex, selectedIndex != NSNotFound {
            tabView?.selectTabViewItem(at: selectedIndex)
        }
    }

    private func harnessRow(_ harness: Harness) -> (NSView, NSSwitch) {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: harness.displayName)
        name.font = ZTheme.monoFont(size: 13, weight: .medium)
        name.textColor = ZTheme.current.fgColor
        name.translatesAutoresizingMaskIntoConstraints = false

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(switchToggled(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(name)
        row.addSubview(toggle)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return (row, toggle)
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = ZTheme.current.fgColor
        return label
    }

    /// A caption label; when `link`/`url` are given, that substring becomes a
    /// clickable hyperlink (accent-colored, per the design rules).
    private func caption(_ text: String, link: String? = nil, url: String? = nil) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = ZTheme.current.fg3Color
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        if let link, let url = url.flatMap(URL.init(string:)),
           let range = text.range(of: link) {
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: ZTheme.current.fg3Color,
            ])
            attributed.addAttributes([
                .link: url,
                .foregroundColor: ZTheme.current.accentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: NSRange(range, in: text))
            label.attributedStringValue = attributed
            // Selectable is what makes the .link attribute clickable in a label.
            label.isSelectable = true
            label.allowsEditingTextAttributes = true
        }
        return label
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 8).isActive = true
        return v
    }

    private func abbreviatedConfigPath() -> String {
        let home = NSHomeDirectory()
        let path = configURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Sessions

    /// Syncs the preserve toggle + status line with the config and zmx state,
    /// and refreshes the orphaned-session count off-main.
    private func refreshSessions() {
        let config = ConfigStore(fileURL: configURL).load()
        preserveSwitch.state = config.preserveSessions ? .on : .off
        confirmQuitSwitch.state = config.confirmQuit ? .on : .off
        notifySoundSwitch.state = config.notifySound ? .on : .off
        notifyBadgeSwitch.state = config.notifyBadge ? .on : .off
        notifySystemSwitch.state = config.notifySystem ? .on : .off

        // Which zmx binary backs the feature is an implementation detail; the
        // status line only appears when zmx is missing, to explain the toggle.
        let zmxPath = ZmxRunner.locate()
        sessionStatusLabel.isHidden = zmxPath != nil
        if zmxPath == nil {
            sessionStatusLabel.stringValue = "zmx not installed — enabling offers to install it"
        }

        orphanButton.isHidden = true
        guard let zmx = zmxPath else { return }
        let liveIDs = liveSurfaceIDs()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let existing = ZmxRunner.listZettySessions(zmxPath: zmx)
            let orphans = SessionPersistence.orphans(existing: existing, liveSurfaceIDs: liveIDs)
            DispatchQueue.main.async {
                guard let self else { return }
                self.orphanSessions = orphans
                self.orphanButton.title = "Kill \(orphans.count) Orphaned Session\(orphans.count == 1 ? "" : "s")"
                self.orphanButton.isHidden = orphans.isEmpty
            }
        }
    }

    @objc private func preserveToggled(_ sender: NSSwitch) {
        let enabling = sender.state == .on
        if !enabling {
            savePreserveSessions(false)
            refreshSessions()
            return
        }

        if ZmxRunner.locate() != nil {
            savePreserveSessions(true)
            refreshSessions()
            return
        }

        // zmx missing: offer to download the release binary into ~/.zetty/bin.
        let alert = NSAlert()
        alert.messageText = "Session preservation requires zmx"
        alert.informativeText = "Download zmx \(ZmxRunner.version) from zmx.sh now? It installs into ~/.zetty/bin — nothing else is touched."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            sender.state = .off
            return
        }

        sender.isEnabled = false
        sessionStatusLabel.stringValue = "Installing zmx…"
        ZmxRunner.install { [weak self] zmxPath in
            guard let self else { return }
            self.preserveSwitch.isEnabled = true
            if zmxPath != nil {
                self.savePreserveSessions(true)
            } else {
                self.preserveSwitch.state = .off
                self.presentAlert(
                    title: "zmx install failed",
                    message: "Install it manually, then re-enable:\n\n\(ZmxRunner.installHint)",
                    warning: true
                )
            }
            self.refreshSessions()
        }
    }

    /// Persists the toggle to the config file; the app's config watcher picks
    /// up the change and re-threads preservation (new panes only).
    private func savePreserveSessions(_ enabled: Bool) {
        let store = ConfigStore(fileURL: configURL)
        var config = store.load()
        config.preserveSessions = enabled
        store.save(config)
    }

    // MARK: - Command Line

    private static var cliLinkURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/zetty")
    }

    /// Syncs the CLI install state (symlink at ~/.local/bin/zetty → this
    /// build's app binary, which runs in CLI mode when given a command).
    private func refreshCLI() {
        let link = Self.cliLinkURL
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        if let destination, destination == Bundle.main.executablePath {
            cliStatusLabel.stringValue = "installed: ~/.local/bin/zetty"
            cliInstallButton.title = "Reinstall CLI"
        } else if FileManager.default.fileExists(atPath: link.path) {
            cliStatusLabel.stringValue = "~/.local/bin/zetty exists but points to another build"
            cliInstallButton.title = "Reinstall CLI"
        } else {
            cliStatusLabel.stringValue = "not installed"
            cliInstallButton.title = "Install CLI"
        }
    }

    @objc private func installCLI(_ sender: Any?) {
        guard let executable = Bundle.main.executablePath else { return }
        let link = Self.cliLinkURL
        let fm = FileManager.default
        try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: executable)
        refreshCLI()
    }

    // MARK: - Behavior

    @objc private func confirmQuitToggled(_ sender: NSSwitch) {
        let store = ConfigStore(fileURL: configURL)
        var config = store.load()
        config.confirmQuit = sender.state == .on
        store.save(config)
    }

    @objc private func notifySoundToggled(_ sender: NSSwitch) {
        let store = ConfigStore(fileURL: configURL)
        var config = store.load()
        config.notifySound = sender.state == .on
        store.save(config)
    }

    @objc private func notifyBadgeToggled(_ sender: NSSwitch) {
        let store = ConfigStore(fileURL: configURL)
        var config = store.load()
        config.notifyBadge = sender.state == .on
        store.save(config)
    }

    @objc private func notifySystemToggled(_ sender: NSSwitch) {
        let store = ConfigStore(fileURL: configURL)
        var config = store.load()
        config.notifySystem = sender.state == .on
        store.save(config)
    }

    @objc private func killOrphans(_ sender: Any?) {
        guard let zmx = ZmxRunner.locate(), !orphanSessions.isEmpty else { return }
        ZmxRunner.kill(sessions: orphanSessions, zmxPath: zmx)
        orphanButton.isHidden = true
        // Re-check shortly after the background kill has had a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshSessions()
        }
    }

    // MARK: - Editor picker

    /// Fills the dropdown with the installed editors (EditorCatalog roster)
    /// and selects the config's current `editor` (appending it if it's
    /// something off-roster, so a hand-set value still shows).
    private func populateEditorPopup() {
        editorApps = EditorCatalog.installed()

        let current = ConfigStore(fileURL: configURL).load().editor?
            .trimmingCharacters(in: .whitespaces) ?? ""

        // A hand-configured editor outside the roster still gets an entry.
        if !current.isEmpty,
           !editorApps.contains(where: { EditorCatalog.matches($0, editor: current) }),
           let url = EditorCatalog.resolve(current) {
            editorApps.append(url)
        }

        editorPopup.removeAllItems()
        editorPopup.addItem(withTitle: "System Default")
        for url in editorApps {
            editorPopup.addItem(withTitle: EditorCatalog.displayName(of: url))
            editorPopup.lastItem?.image = EditorCatalog.icon(for: url, size: 16)
        }

        if !current.isEmpty,
           let index = editorApps.firstIndex(where: { EditorCatalog.matches($0, editor: current) }) {
            editorPopup.selectItem(at: index + 1)
        } else {
            editorPopup.selectItem(at: 0)
        }
    }

    /// Persists the picked editor to the config (`nil` for System Default).
    @objc private func editorPicked(_ sender: NSPopUpButton) {
        let store = ConfigStore(fileURL: configURL)
        var config = store.load()
        let index = sender.indexOfSelectedItem
        config.editor = index <= 0 || index > editorApps.count
            ? nil
            : EditorCatalog.displayName(of: editorApps[index - 1])
        store.save(config)
    }

    // MARK: - Actions

    /// Opens the config in the app named by the config's `editor` key (app name
    /// or bundle id); when unset/unresolvable, the system default app for the
    /// file. Seeds the file first so there's something to open.
    @objc private func openConfig(_ sender: Any?) {
        let store = ConfigStore(fileURL: configURL)
        store.writeDefaultIfMissing()
        if let editor = store.load().editor, let appURL = EditorCatalog.resolve(editor) {
            NSWorkspace.shared.open([configURL], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(configURL)
        }
    }

    @objc private func switchToggled(_ sender: NSSwitch) {
        guard let harness = switches.first(where: { $0.control === sender })?.harness else { return }
        let outcome = sender.state == .on ? installer.install(harness) : installer.uninstall(harness)
        switch outcome {
        case .installed, .uninstalled, .alreadyInstalled:
            break   // the switch already reflects the new state
        case let .conflict(snippet):
            sender.state = .off
            presentAlert(title: "\(harness.displayName): manual step needed",
                         message: "A hooks: block already exists in your config, so add these entries yourself:\n\n\(snippet)")
        case let .failed(message):
            sender.state = (sender.state == .on) ? .off : .on   // revert
            presentAlert(title: "\(harness.displayName) hook change failed", message: message, warning: true)
        }
    }

    private func presentAlert(title: String, message: String, warning: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if warning { alert.alertStyle = .warning }
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

// MARK: - Font control commits (NSComboBoxDelegate)

extension SettingsWindowController: NSComboBoxDelegate {

    /// Dropdown item clicks don't fire the combo's target/action — they land
    /// here. `stringValue` is still stale at this point, so read the selected
    /// item directly.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo === fontCombo else { return }
        let index = combo.indexOfSelectedItem
        guard index >= 0, let item = combo.itemObjectValue(at: index) as? String else { return }
        commitFontFamily(item)
    }

    /// Typed values commit on focus loss, not just Enter.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let control = notification.object as? NSControl else { return }
        if control === fontCombo {
            commitFontFamily(fontCombo.stringValue)
        } else if control === fontSizeField {
            commitFontSize(fontSizeField.stringValue)
        }
    }
}
