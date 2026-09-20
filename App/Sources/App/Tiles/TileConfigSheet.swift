import AppKit
import ZettyCore

/// Names a tile view and picks its grid.
///
/// It asks for columns and rows and nothing else. It used to open with the
/// layout presets as well, which is a dead end wherever it is reached from:
/// the chooser IS that list, so the sheet behind its "Custom…" card offered
/// the eight shapes the user had just declined.
///
/// The shape is drawn as it is dialled rather than described as "3x2", for the
/// same reason the chooser shows pictures — a grid is a thing you recognise,
/// not a string you parse.
@MainActor
final class TileConfigSheet: NSViewController {

    struct Result {
        let name: String
        let root: TileNode
        /// Non-nil when the user asked to keep this shape in the library.
        let saveAsLayout: String?
    }

    private let initialName: String
    private let confirmTitle: String
    private let onConfirm: (Result) -> Void

    private let nameField = NSTextField()
    private let columnsStepper = NSStepper()
    private let rowsStepper = NSStepper()
    private let columnsValue = NSTextField(labelWithString: "")
    private let rowsValue = NSTextField(labelWithString: "")
    private let previewView = NSImageView()
    private let saveToggle = NSButton()
    private let saveNameField = NSTextField()

    private static let previewSize: CGFloat = 84

    /// The shape being configured. Always uniform here — a non-uniform tree is
    /// made by splitting slots in the grid itself, not by dialling numbers.
    private var grid: TilesGrid {
        didSet {
            guard oldValue != grid else { return }
            syncGridControls()
        }
    }

    init(name: String = "",
         grid: TilesGrid = .default,
         confirmTitle: String = "Create",
         onConfirm: @escaping (Result) -> Void) {
        self.initialName = name
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

        let sizeLabel = label("Size")
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.contentTintColor = theme.fg2Color
        previewView.translatesAutoresizingMaskIntoConstraints = false

        configureStepper(columnsStepper)
        configureStepper(rowsStepper)
        let counts = NSStackView(views: [
            countRow(label("Columns"), columnsValue, columnsStepper),
            countRow(label("Rows"), rowsValue, rowsStepper),
        ])
        counts.orientation = .vertical
        counts.alignment = .leading
        counts.spacing = 8
        counts.translatesAutoresizingMaskIntoConstraints = false

        saveToggle.setButtonType(.switch)
        saveToggle.title = "Save as layout"
        saveToggle.font = ZTheme.chromeFont(size: 12)
        saveToggle.target = self
        saveToggle.action = #selector(saveToggled)
        saveToggle.translatesAutoresizingMaskIntoConstraints = false
        saveNameField.placeholderString = "Layout name"
        saveNameField.font = ZTheme.chromeFont(size: 12)
        saveNameField.isEnabled = false
        saveNameField.translatesAutoresizingMaskIntoConstraints = false
        let saveRow = NSStackView(views: [saveToggle, saveNameField])
        saveRow.orientation = .horizontal
        saveRow.spacing = 8
        saveRow.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: confirmTitle, target: self, action: #selector(confirmClicked))
        confirm.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [nameLabel, nameField, sizeLabel, previewView, counts, saveRow, buttons] {
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 380),

            nameLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            nameField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            nameField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            sizeLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 18),
            sizeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            previewView.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 8),
            previewView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            previewView.widthAnchor.constraint(equalToConstant: Self.previewSize),
            previewView.heightAnchor.constraint(equalToConstant: Self.previewSize),

            counts.leadingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: 18),
            counts.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),
            counts.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                             constant: -20),

            saveRow.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 18),
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

    /// `Columns  3 ▲▼` — the number is spelled out beside the stepper, which
    /// on its own shows nothing at all.
    private func countRow(_ caption: NSTextField,
                          _ value: NSTextField,
                          _ stepper: NSStepper) -> NSStackView {
        value.font = ZTheme.chromeFont(size: 12)
        value.textColor = ZTheme.current.fgColor
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            caption.widthAnchor.constraint(equalToConstant: 58),
            value.widthAnchor.constraint(equalToConstant: 16),
        ])
        let row = NSStackView(views: [caption, value, stepper])
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func configureStepper(_ stepper: NSStepper) {
        // The same 1...8 `TilesGrid` clamps to, so the control cannot ask for
        // something the model will silently refuse.
        stepper.minValue = 1
        stepper.maxValue = Double(TilesGrid.maxSide)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        stepper.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Draws the grid as its own shape. A picture is the point of naming a
    /// layout — "2x3" is not something anyone reads at a glance.
    static func shapeImage(for root: TileNode, size: CGFloat = 32) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let gap: CGFloat = 2
            ZTheme.current.fg2Color.setFill()
            // Straight from the layout engine, so a non-uniform shape draws as
            // itself rather than as the nearest grid.
            for frame in root.frames(in: LayoutRect(x: 0, y: 0, width: 1, height: 1)) {
                let cell = NSRect(
                    x: CGFloat(frame.x) * rect.width + gap / 2,
                    // LayoutRect is top-left-origin; NSImage drawing is not.
                    y: rect.height - CGFloat(frame.y + frame.height) * rect.height + gap / 2,
                    width: CGFloat(frame.width) * rect.width - gap,
                    height: CGFloat(frame.height) * rect.height - gap)
                NSBezierPath(roundedRect: cell, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        // Template, so `contentTintColor` reaches it: the chooser tints a
        // hovered card and this sheet tints its preview. The fill colour above
        // is only the silhouette AppKit re-tints.
        image.isTemplate = true
        return image
    }

    // MARK: - State

    private func syncGridControls() {
        columnsStepper.integerValue = grid.columns
        rowsStepper.integerValue = grid.rows
        columnsValue.stringValue = "\(grid.columns)"
        rowsValue.stringValue = "\(grid.rows)"
        previewView.image = Self.shapeImage(for: TileNode.uniform(grid),
                                            size: Self.previewSize)
    }

    @objc private func saveToggled() {
        saveNameField.isEnabled = saveToggle.state == .on
        if saveToggle.state == .on { view.window?.makeFirstResponder(saveNameField) }
    }

    @objc private func stepperChanged() {
        grid = TilesGrid(columns: columnsStepper.integerValue,
                         rows: rowsStepper.integerValue)
    }

    @objc private func cancelClicked() { dismiss(nil) }

    @objc private func confirmClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let saveName = saveNameField.stringValue.trimmingCharacters(in: .whitespaces)
        let result = Result(
            name: name.isEmpty ? "Tiles" : name,
            root: TileNode.uniform(grid),
            saveAsLayout: (saveToggle.state == .on && !saveName.isEmpty) ? saveName : nil)
        dismiss(nil)
        onConfirm(result)
    }
}
