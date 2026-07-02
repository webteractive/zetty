import AppKit
import QuerttyCore

/// A small themed Settings window. Currently hosts the **Agent Status Hooks**
/// section — a toggle per harness that installs/uninstalls quertty's status hook.
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

    // Sessions section controls.
    private let preserveSwitch = NSSwitch()
    private let sessionStatusLabel = NSTextField(labelWithString: "")
    private let orphanButton = NSButton(title: "", target: nil, action: nil)
    private var orphanSessions: [String] = []

    // Appearance section controls.
    private let appearancePopup = NSPopUpButton()
    private let darkThemePopup = NSPopUpButton()
    private let lightThemePopup = NSPopUpButton()

    /// Called when the user picks an appearance mode (owner applies + persists).
    var onSetAppearance: ((AppearanceMode) -> Void)?

    /// Called when the user picks a color scheme (owner applies + persists).
    var onSelectTheme: ((QColorScheme) -> Void)?

    init(installer: HookInstaller, liveSurfaceIDs: @escaping () -> [UUID] = { [] }) {
        self.installer = installer
        self.liveSurfaceIDs = liveSurfaceIDs
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.appearance = QTheme.current.appearance
        window.backgroundColor = QTheme.current.bg1Color
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
        refreshSessions()
    }

    // MARK: - Content

    private func buildContent() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = QTheme.current.bg1Color.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])

        // Configuration section.
        stack.addArrangedSubview(sectionHeader("Configuration"))
        stack.addArrangedSubview(caption(abbreviatedConfigPath()))
        stack.addArrangedSubview(caption(
            "appearance, theme-dark, theme-light and preserve-sessions are quertty's own keys; "
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

        // Appearance section.
        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(sectionHeader("Appearance"))
        appearancePopup.removeAllItems()
        appearancePopup.addItems(withTitles: AppearanceMode.allCases.map { $0.rawValue.capitalized })
        appearancePopup.target = self
        appearancePopup.action = #selector(appearancePicked(_:))
        darkThemePopup.removeAllItems()
        darkThemePopup.addItems(withTitles: QColorScheme.darkSchemes.map(\.displayName))
        darkThemePopup.target = self
        darkThemePopup.action = #selector(darkThemePicked(_:))
        lightThemePopup.removeAllItems()
        lightThemePopup.addItems(withTitles: QColorScheme.lightSchemes.map(\.displayName))
        lightThemePopup.target = self
        lightThemePopup.action = #selector(lightThemePicked(_:))
        for (title, popup) in [
            ("Appearance", appearancePopup),
            ("Dark theme", darkThemePopup),
            ("Light theme", lightThemePopup),
        ] {
            let row = popupRow(title, popup: popup)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Behavior section.
        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(sectionHeader("Behavior"))
        confirmQuitSwitch.target = self
        confirmQuitSwitch.action = #selector(confirmQuitToggled(_:))
        let confirmRow = switchRow("Confirm before quitting", control: confirmQuitSwitch)
        stack.addArrangedSubview(confirmRow)
        confirmRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Sessions section.
        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(sectionHeader("Sessions"))
        stack.addArrangedSubview(caption(
            "Keep terminal sessions running when quertty quits, and reattach them on relaunch. Powered by zmx.",
            link: "zmx", url: "https://github.com/neurosnap/zmx"
        ))

        let preserveRow = NSView()
        preserveRow.translatesAutoresizingMaskIntoConstraints = false
        let preserveLabel = NSTextField(labelWithString: "Preserve sessions")
        preserveLabel.font = QTheme.monoFont(size: 13, weight: .medium)
        preserveLabel.textColor = QTheme.current.fgColor
        preserveLabel.translatesAutoresizingMaskIntoConstraints = false
        preserveSwitch.target = self
        preserveSwitch.action = #selector(preserveToggled(_:))
        preserveSwitch.translatesAutoresizingMaskIntoConstraints = false
        preserveRow.addSubview(preserveLabel)
        preserveRow.addSubview(preserveSwitch)
        NSLayoutConstraint.activate([
            preserveRow.heightAnchor.constraint(equalToConstant: 28),
            preserveLabel.leadingAnchor.constraint(equalTo: preserveRow.leadingAnchor),
            preserveLabel.centerYAnchor.constraint(equalTo: preserveRow.centerYAnchor),
            preserveSwitch.trailingAnchor.constraint(equalTo: preserveRow.trailingAnchor),
            preserveSwitch.centerYAnchor.constraint(equalTo: preserveRow.centerYAnchor),
        ])
        stack.addArrangedSubview(preserveRow)
        preserveRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        sessionStatusLabel.font = QTheme.monoFont(size: 11)
        sessionStatusLabel.textColor = QTheme.current.fg3Color
        stack.addArrangedSubview(sessionStatusLabel)

        orphanButton.bezelStyle = .rounded
        orphanButton.target = self
        orphanButton.action = #selector(killOrphans(_:))
        orphanButton.isHidden = true
        stack.addArrangedSubview(orphanButton)

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(sectionHeader("Agent Status Hooks"))
        stack.addArrangedSubview(caption(
            "Install a hook so the harness reports agent status to quertty. "
            + "Status shows as sidebar dots — green running, yellow needs-attention, dim idle."
        ))

        for harness in Harness.allCases {
            let (row, control) = harnessRow(harness)
            switches.append((harness, control))
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        stack.addArrangedSubview(caption("Restart the agent after enabling for the hook to take effect."))
        refresh()
        return root
    }

    /// A justified label + switch row (same anatomy as the harness rows).
    private func switchRow(_ title: String, control: NSSwitch) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = QTheme.monoFont(size: 13, weight: .medium)
        label.textColor = QTheme.current.fgColor
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
        label.font = QTheme.monoFont(size: 13, weight: .medium)
        label.textColor = QTheme.current.fgColor
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

    // MARK: - Appearance

    /// Syncs the appearance + theme popups with the config on disk.
    private func refreshAppearance() {
        let config = ConfigStore(fileURL: configURL).load()
        if let index = AppearanceMode.allCases.firstIndex(of: config.appearance) {
            appearancePopup.selectItem(at: index)
        }
        let dark = QColorScheme.named(config.themeDark) ?? .midnight
        if let index = QColorScheme.darkSchemes.firstIndex(of: dark) {
            darkThemePopup.selectItem(at: index)
        }
        let light = QColorScheme.named(config.themeLight) ?? .paper
        if let index = QColorScheme.lightSchemes.firstIndex(of: light) {
            lightThemePopup.selectItem(at: index)
        }
    }

    @objc private func appearancePicked(_ sender: NSPopUpButton) {
        let modes = AppearanceMode.allCases
        guard (0..<modes.count).contains(sender.indexOfSelectedItem) else { return }
        onSetAppearance?(modes[sender.indexOfSelectedItem])
        rebuildAfterThemeChange()
    }

    @objc private func darkThemePicked(_ sender: NSPopUpButton) {
        let schemes = QColorScheme.darkSchemes
        guard (0..<schemes.count).contains(sender.indexOfSelectedItem) else { return }
        onSelectTheme?(schemes[sender.indexOfSelectedItem])
        rebuildAfterThemeChange()
    }

    @objc private func lightThemePicked(_ sender: NSPopUpButton) {
        let schemes = QColorScheme.lightSchemes
        guard (0..<schemes.count).contains(sender.indexOfSelectedItem) else { return }
        onSelectTheme?(schemes[sender.indexOfSelectedItem])
        rebuildAfterThemeChange()
    }

    /// Re-themes this window after an appearance/scheme change made from it:
    /// token colors are baked into the labels at build time, so the content is
    /// rebuilt against the new palette.
    private func rebuildAfterThemeChange() {
        switches.removeAll()
        window?.appearance = QTheme.current.appearance
        window?.backgroundColor = QTheme.current.bg1Color
        window?.contentView = buildContent()
    }

    private func harnessRow(_ harness: Harness) -> (NSView, NSSwitch) {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: harness.displayName)
        name.font = QTheme.monoFont(size: 13, weight: .medium)
        name.textColor = QTheme.current.fgColor
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
        label.textColor = QTheme.current.fgColor
        return label
    }

    /// A caption label; when `link`/`url` are given, that substring becomes a
    /// clickable hyperlink (accent-colored, per the design rules).
    private func caption(_ text: String, link: String? = nil, url: String? = nil) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = QTheme.current.fg3Color
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        if let link, let url = url.flatMap(URL.init(string:)),
           let range = text.range(of: link) {
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: QTheme.current.fg3Color,
            ])
            attributed.addAttributes([
                .link: url,
                .foregroundColor: QTheme.current.accentColor,
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
            let existing = ZmxRunner.listQuerttySessions(zmxPath: zmx)
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

        // zmx missing: offer to download the release binary into ~/.quertty/bin.
        let alert = NSAlert()
        alert.messageText = "Session preservation requires zmx"
        alert.informativeText = "Download zmx \(ZmxRunner.version) from zmx.sh now? It installs into ~/.quertty/bin — nothing else is touched."
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

    // MARK: - Behavior

    @objc private func confirmQuitToggled(_ sender: NSSwitch) {
        let store = ConfigStore(fileURL: configURL)
        var config = store.load()
        config.confirmQuit = sender.state == .on
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

    /// Curated roster of popular editors (bundle ids). The dropdown shows the
    /// intersection of this list with what's installed — apps like browsers that
    /// merely *register* for text files stay out. The `editor` config key remains
    /// the escape hatch for anything not listed.
    private static let knownEditors: [String] = [
        "dev.zed.Zed",                       // Zed
        "com.microsoft.VSCode",              // Visual Studio Code
        "com.todesktop.230313mzl4w4u92",     // Cursor
        "com.exafunction.windsurf",          // Windsurf
        "com.sublimetext.4",                 // Sublime Text 4
        "com.sublimetext.3",                 // Sublime Text 3
        "com.barebones.bbedit",              // BBEdit
        "com.macromates.TextMate",           // TextMate
        "com.panic.Nova",                    // Nova
        "com.jetbrains.fleet",               // Fleet
        "com.apple.dt.Xcode",                // Xcode
        "com.apple.TextEdit",                // TextEdit
    ]

    /// Fills the dropdown with the installed subset of `knownEditors` and
    /// selects the config's current `editor` (appending it if it's something
    /// off-roster, so a hand-set value still shows).
    private func populateEditorPopup() {
        var seen = Set<String>()
        editorApps = Self.knownEditors
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .filter { seen.insert($0.deletingPathExtension().lastPathComponent.lowercased()).inserted }

        let current = ConfigStore(fileURL: configURL).load().editor?
            .trimmingCharacters(in: .whitespaces) ?? ""

        // A hand-configured editor outside the roster still gets an entry.
        if !current.isEmpty,
           !editorApps.contains(where: { Self.matches($0, editor: current) }),
           let url = Self.resolveEditor(current) {
            editorApps.append(url)
        }

        editorPopup.removeAllItems()
        editorPopup.addItem(withTitle: "System Default")
        for url in editorApps {
            editorPopup.addItem(withTitle: url.deletingPathExtension().lastPathComponent)
        }

        if !current.isEmpty,
           let index = editorApps.firstIndex(where: { Self.matches($0, editor: current) }) {
            editorPopup.selectItem(at: index + 1)
        } else {
            editorPopup.selectItem(at: 0)
        }
    }

    /// True if the app at `url` is the one the `editor` value names.
    private static func matches(_ url: URL, editor: String) -> Bool {
        url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(editor) == .orderedSame
            || Bundle(url: url)?.bundleIdentifier?.caseInsensitiveCompare(editor) == .orderedSame
    }

    /// Persists the picked editor to the config (`nil` for System Default).
    @objc private func editorPicked(_ sender: NSPopUpButton) {
        let store = ConfigStore(fileURL: configURL)
        var config = store.load()
        let index = sender.indexOfSelectedItem
        config.editor = index <= 0 || index > editorApps.count
            ? nil
            : editorApps[index - 1].deletingPathExtension().lastPathComponent
        store.save(config)
    }

    // MARK: - Actions

    /// Opens the config in the app named by the config's `editor` key (app name
    /// or bundle id); when unset/unresolvable, the system default app for the
    /// file. Seeds the file first so there's something to open.
    @objc private func openConfig(_ sender: Any?) {
        let store = ConfigStore(fileURL: configURL)
        store.writeDefaultIfMissing()
        if let editor = store.load().editor, let appURL = Self.resolveEditor(editor) {
            NSWorkspace.shared.open([configURL], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(configURL)
        }
    }

    /// Resolves an `editor` value to an app URL: bundle id first, then an app
    /// name looked up in the standard Applications folders.
    private static func resolveEditor(_ editor: String) -> URL? {
        let trimmed = editor.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return url
        }
        let name = trimmed.hasSuffix(".app") ? trimmed : trimmed + ".app"
        let candidates = [
            "/Applications/\(name)",
            "\(NSHomeDirectory())/Applications/\(name)",
            "/System/Applications/\(name)",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
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
