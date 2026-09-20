import AppKit
import ZettyCore

/// Names a tile view and picks its grid — shown when a view is created, and
/// again when one is reconfigured.
///
/// Presets are drawn as their own shape rather than listed as "2x3", because
/// picking a picture is the whole point of a layout having a name.
@MainActor
final class TileConfigSheet: NSViewController {

    struct Result {
        let name: String
        let grid: TilesGrid
        /// Non-nil when the user asked to keep this shape in the library.
        let saveAsLayout: String?
    }

    private let layouts: [TileLayout]
    private let initialName: String
    private let initialGrid: TilesGrid
    private let confirmTitle: String
    private let onConfirm: (Result) -> Void

    private let nameField = NSTextField()
    private var presetButtons: [NSButton] = []
    private let customToggle = NSButton()
    private let columnsStepper = NSStepper()
    private let rowsStepper = NSStepper()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let saveToggle = NSButton()
    private let saveNameField = NSTextField()
    private let customRow = NSStackView()
    private let saveRow = NSStackView()

    private var grid: TilesGrid {
        didSet {
            guard oldValue != grid else { return }
            syncGridControls()
        }
    }

    init(layouts: [TileLayout],
         name: String = "",
         grid: TilesGrid = .default,
         confirmTitle: String = "Create",
         onConfirm: @escaping (Result) -> Void) {
        self.layouts = layouts
        self.initialName = name
        self.initialGrid = grid
        self.grid = grid
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let theme = ZTheme.current
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.bg1Color.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = label("Name")
        nameField.stringValue = initialName
        nameField.font = ZTheme.chromeFont(size: 12)
        nameField.placeholderString = "Tiles"
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let layoutLabel = label("Layout")
        let presets = NSStackView()
        presets.orientation = .horizontal
        presets.spacing = 10
        presets.translatesAutoresizingMaskIntoConstraints = false
        for (index, layout) in layouts.enumerated() {
            let button = presetButton(for: layout, tag: index)
            presetButtons.append(button)
            presets.addArrangedSubview(button)
        }

        customToggle.setButtonType(.switch)
        customToggle.title = "Custom"
        customToggle.font = ZTheme.chromeFont(size: 12)
        customToggle.target = self
        customToggle.action = #selector(customToggled)
        customToggle.translatesAutoresizingMaskIntoConstraints = false

        configureStepper(columnsStepper, action: #selector(stepperChanged))
        configureStepper(rowsStepper, action: #selector(stepperChanged))
        sizeLabel.font = ZTheme.chromeFont(size: 12)
        sizeLabel.textColor = theme.fg2Color

        customRow.orientation = .horizontal
        customRow.spacing = 8
        customRow.translatesAutoresizingMaskIntoConstraints = false
        customRow.addArrangedSubview(label("Columns"))
        customRow.addArrangedSubview(columnsStepper)
        customRow.addArrangedSubview(label("Rows"))
        customRow.addArrangedSubview(rowsStepper)
        customRow.addArrangedSubview(sizeLabel)
        customRow.isHidden = true

        saveToggle.setButtonType(.switch)
        saveToggle.title = "Save as layout"
        saveToggle.font = ZTheme.chromeFont(size: 12)
        saveToggle.target = self
        saveToggle.action = #selector(saveToggled)
        saveNameField.placeholderString = "Layout name"
        saveNameField.font = ZTheme.chromeFont(size: 12)
        saveNameField.isEnabled = false
        saveNameField.translatesAutoresizingMaskIntoConstraints = false
        saveRow.orientation = .horizontal
        saveRow.spacing = 8
        saveRow.translatesAutoresizingMaskIntoConstraints = false
        saveRow.addArrangedSubview(saveToggle)
        saveRow.addArrangedSubview(saveNameField)
        saveRow.isHidden = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: confirmTitle, target: self, action: #selector(confirmClicked))
        confirm.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [nameLabel, nameField, layoutLabel, presets, customToggle,
                     customRow, saveRow, buttons] {
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 480),

            nameLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            nameField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            nameField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            layoutLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 18),
            layoutLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            presets.topAnchor.constraint(equalTo: layoutLabel.bottomAnchor, constant: 8),
            presets.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            presets.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                              constant: -20),

            customToggle.topAnchor.constraint(equalTo: presets.bottomAnchor, constant: 16),
            customToggle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            customRow.topAnchor.constraint(equalTo: customToggle.bottomAnchor, constant: 8),
            customRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            customRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                                constant: -20),

            saveRow.topAnchor.constraint(equalTo: customRow.bottomAnchor, constant: 10),
            saveRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            saveRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            buttons.topAnchor.constraint(equalTo: saveRow.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])

        view = root
        syncGridControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    // MARK: - Pieces

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = ZTheme.chromeFont(size: 12)
        field.textColor = ZTheme.current.fg2Color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func configureStepper(_ stepper: NSStepper, action: Selector) {
        // The same 1...8 `TilesGrid` clamps to, so the control cannot ask for
        // something the model will silently refuse.
        stepper.minValue = 1
        stepper.maxValue = Double(TilesGrid.maxSide)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action
        stepper.translatesAutoresizingMaskIntoConstraints = false
    }

    private func presetButton(for layout: TileLayout, tag: Int) -> NSButton {
        let button = NSButton(title: layout.name, target: self, action: #selector(presetPicked(_:)))
        button.tag = tag
        button.bezelStyle = .smallSquare
        button.imagePosition = .imageAbove
        button.image = TileConfigSheet.shapeImage(for: layout.grid)
        button.font = ZTheme.chromeFont(size: 11)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 64),
            button.heightAnchor.constraint(equalToConstant: 60),
        ])
        return button
    }

    /// Draws the grid as its own shape. A picture is the point of naming a
    /// layout — "2x3" is not something anyone reads at a glance.
    static func shapeImage(for grid: TilesGrid, size: CGFloat = 32) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let theme = ZTheme.current
            let gap: CGFloat = 2
            let cellWidth = (rect.width - gap * CGFloat(grid.columns - 1)) / CGFloat(grid.columns)
            let cellHeight = (rect.height - gap * CGFloat(grid.rows - 1)) / CGFloat(grid.rows)
            theme.fg2Color.setFill()
            for column in 0..<grid.columns {
                for row in 0..<grid.rows {
                    let cell = NSRect(x: CGFloat(column) * (cellWidth + gap),
                                      y: rect.height - cellHeight
                                          - CGFloat(row) * (cellHeight + gap),
                                      width: cellWidth, height: cellHeight)
                    NSBezierPath(roundedRect: cell, xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - State

    private func syncGridControls() {
        columnsStepper.integerValue = grid.columns
        rowsStepper.integerValue = grid.rows
        sizeLabel.stringValue = grid.configValue
        for (index, button) in presetButtons.enumerated() {
            let matches = layouts.indices.contains(index) && layouts[index].grid == grid
            button.contentTintColor = matches
                ? ZTheme.current.accentColor
                : ZTheme.current.fg2Color
        }
    }

    @objc private func presetPicked(_ sender: NSButton) {
        guard layouts.indices.contains(sender.tag) else { return }
        grid = layouts[sender.tag].grid
        customToggle.state = .off
        customRow.isHidden = true
        saveRow.isHidden = true
    }

    @objc private func customToggled() {
        let on = customToggle.state == .on
        customRow.isHidden = !on
        saveRow.isHidden = !on
    }

    @objc private func saveToggled() {
        saveNameField.isEnabled = saveToggle.state == .on
        if saveToggle.state == .on { view.window?.makeFirstResponder(saveNameField) }
    }

    @objc private func stepperChanged() {
        grid = TilesGrid(columns: columnsStepper.integerValue, rows: rowsStepper.integerValue)
    }

    @objc private func cancelClicked() { dismiss(nil) }

    @objc private func confirmClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let saveName = saveNameField.stringValue.trimmingCharacters(in: .whitespaces)
        let result = Result(
            name: name.isEmpty ? "Tiles" : name,
            grid: grid,
            saveAsLayout: (saveToggle.state == .on && !saveName.isEmpty) ? saveName : nil)
        dismiss(nil)
        onConfirm(result)
    }
}
