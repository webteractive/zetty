import AppKit
import QuerttyCore

/// A small themed Settings window. Currently hosts the **Agent Status Hooks**
/// section — a toggle per harness that installs/uninstalls quertty's status hook.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let installer: HookInstaller
    private var switches: [(harness: Harness, control: NSSwitch)] = []
    private let configURL = ConfigStore().fileURL

    /// Detected text-capable apps backing the editor dropdown (parallel to its
    /// items after the leading "System Default").
    private let editorPopup = NSPopUpButton()
    private var editorApps: [URL] = []

    init(installer: HookInstaller) {
        self.installer = installer
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
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

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = QTheme.current.fg3Color
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
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
