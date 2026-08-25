import AppKit

/// A small editor for a Space's name, color, and glyph — used for both
/// "New Space…" (empty name, invoked from a project row's "Move to Space ▸"
/// submenu) and "Rename…"/"Edit Space…" (prefilled from the current Space).
/// Hosted in an `NSAlert` accessory view — the established small-sheet
/// pattern (see `TerminalViewController.promptCloneProject`) — rather than a
/// full custom `NSWindow` like `ProjectSettingsSheet`; this editor is small
/// enough not to need one. The palette row and `IconPicker` construction are
/// copied from `ProjectSettingsSheet` so the two editors look identical.
@MainActor
enum SpaceSheet {
    /// Presents the Space editor over `window`. `onSave` receives the trimmed
    /// name plus the chosen palette id and SF Symbol/emoji (nil = default).
    /// Not invoked on Cancel, nor on a blank/whitespace-only name.
    static func present(over window: NSWindow,
                        name: String,
                        colorID: String?,
                        glyph: String?,
                        onSave: @escaping (String, String?, String?) -> Void) {
        SpaceSheetController.present(over: window, name: name, colorID: colorID, glyph: glyph, onSave: onSave)
    }
}

/// Backing controller for `SpaceSheet` — an `NSObject` so the swatch row can
/// carry an `@objc` target (an `enum` can't be one). Kept alive via `active`
/// until the alert's completion handler runs, mirroring
/// `ProjectSettingsSheet.active`.
private final class SpaceSheetController: NSObject {
    private static var active: SpaceSheetController?

    private let isNew: Bool
    private let nameField: NSTextField
    private var swatchButtons: [NSButton] = []
    private var selectedColorID: String?
    private let iconPicker: IconPickerControl

    private init(name: String, colorID: String?, glyph: String?) {
        isNew = name.isEmpty
        nameField = NSTextField(string: name)
        selectedColorID = colorID
        iconPicker = IconPickerControl(selected: glyph)
        super.init()
        nameField.placeholderString = "Space name"
        nameField.font = ZTheme.chromeFont(size: 13)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
    }

    static func present(over window: NSWindow, name: String, colorID: String?, glyph: String?,
                        onSave: @escaping (String, String?, String?) -> Void) {
        let controller = SpaceSheetController(name: name, colorID: colorID, glyph: glyph)
        active = controller
        controller.show(over: window, onSave: onSave)
    }

    private func show(over window: NSWindow, onSave: @escaping (String, String?, String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = isNew ? "New Space" : "Edit Space"
        alert.informativeText = "Groups related projects under a shared header in the sidebar."
        alert.addButton(withTitle: isNew ? "Create" : "Save")
        alert.addButton(withTitle: "Cancel")

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 6
        let noneSwatch = makeSwatch(color: nil, tooltip: "Default")
        swatchButtons.append(noneSwatch)
        colorRow.addArrangedSubview(noneSwatch)
        for entry in ZTheme.projectPalette {
            // Appearance-reactive: show the variant the header will use.
            let swatch = makeSwatch(color: ZTheme.projectColor(id: entry.id), tooltip: entry.id)
            swatchButtons.append(swatch)
            colorRow.addArrangedSubview(swatch)
        }
        refreshSwatchSelection()

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = ZTheme.chromeFont(size: 11)
            field.textColor = ZTheme.current.fg3Color
            return field
        }

        let stack = NSStackView(views: [
            nameField,
            label("Color"), colorRow,
            label("Icon"), iconPicker,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField

        let nameFieldRef = nameField
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            defer { SpaceSheetController.active = nil }
            guard response == .alertFirstButtonReturn, let self else { return }
            let trimmed = nameFieldRef.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onSave(trimmed, self.selectedColorID, self.iconPicker.selectedIcon)
        }
        alert.beginSheetModal(for: window, completionHandler: complete)
    }

    // MARK: - Palette row (copied from ProjectSettingsSheet)

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
}
