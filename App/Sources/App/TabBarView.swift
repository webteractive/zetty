import AppKit

// MARK: - TabBarView

/// A horizontal strip of clickable segment buttons representing the open tabs.
///
/// Uses `NSSegmentedControl` in `.selectOne` mode so exactly one tab is always
/// selected.  Changes are reported back to the owner via the `onSelect` closure.
/// The tab *model* lives in `QuerttyCore.TabList`; this view only renders it.
///
/// Double-clicking the selected segment shows a temporary `NSTextField` overlay
/// so the user can rename the tab inline.  Committing (Enter / blur) fires
/// `onRenameTab(index, newName)`.  Escaping cancels without a callback.
@MainActor
final class TabBarView: NSView {

    // MARK: - Subviews

    private let segmented: NSSegmentedControl

    // MARK: - Callbacks

    /// Called with the tab index whenever the user clicks a segment.
    var onSelect: ((Int) -> Void)?

    /// Called when the user wants to add a new tab (+ button).
    var onNewTab: (() -> Void)?

    /// Called when the user commits a rename.  `newName` is the raw text; pass
    /// `""` to clear `manualTitle` (revert to auto).
    var onRenameTab: ((Int, String) -> Void)?

    /// Supplies the RAW manual title for a tab index (nil/empty when auto-named),
    /// so the rename field pre-fills with the user's own name rather than the
    /// rendered auto label (which would otherwise freeze the auto name on commit).
    var currentManualTitle: ((Int) -> String?)?

    // MARK: - Inline-edit state

    /// The transient field shown while the user is renaming a segment.
    private var editingField: RenameTextField?

    /// Index of the segment currently being edited (–1 when none).
    private var editingIndex: Int = -1

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        segmented = NSSegmentedControl()
        segmented.segmentStyle = .texturedSquare
        segmented.trackingMode = .selectOne
        segmented.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // "+" new-tab button
        let addButton = NSButton(title: "+", target: nil, action: nil)
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        addButton.target = self
        addButton.action = #selector(addButtonClicked(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(segmented)
        addSubview(addButton)

        segmented.target = self
        segmented.action = #selector(segmentChanged(_:))

        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            segmented.centerYAnchor.constraint(equalTo: centerYAnchor),
            segmented.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
            segmented.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),

            addButton.leadingAnchor.constraint(equalTo: segmented.trailingAnchor, constant: 6),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // MARK: - Update

    /// Rebuilds segments from `titles` and marks `selectedIndex` as selected.
    func update(titles: [String], selectedIndex: Int) {
        // Dismiss any active edit field — the model changed underneath it.
        cancelRename()
        segmented.segmentCount = titles.count
        for (i, title) in titles.enumerated() {
            segmented.setLabel(title, forSegment: i)
            segmented.setWidth(0, forSegment: i)  // auto-width
        }
        if titles.indices.contains(selectedIndex) {
            segmented.selectedSegment = selectedIndex
        }
    }

    // MARK: - Actions

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard idx >= 0 else { return }
        onSelect?(idx)
    }

    @objc private func addButtonClicked(_: Any?) {
        onNewTab?()
    }

    // MARK: - Double-click detection

    override func mouseDown(with event: NSEvent) {
        // Only intercept double-clicks on the segmented control; pass everything
        // else through so single-click selection continues to work normally.
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }

        let locationInSegmented = segmented.convert(event.locationInWindow, from: nil)
        guard segmented.bounds.contains(locationInSegmented) else {
            super.mouseDown(with: event)
            return
        }

        let tappedSegment = segment(at: locationInSegmented)
        guard tappedSegment >= 0 else {
            super.mouseDown(with: event)
            return
        }

        beginRename(at: tappedSegment)
    }

    /// Returns the segment index whose visual frame contains `point` (in the
    /// segmented control's own coordinate space), or –1 if none.
    private func segment(at point: CGPoint) -> Int {
        let count = segmented.segmentCount
        guard count > 0 else { return -1 }

        // NSSegmentedControl lays segments out left-to-right.  We compute each
        // segment's cumulative x-offset by summing the widths reported by the
        // control.  `width(forSegment:)` returns the _actual_ rendered width
        // (even when 0 was passed to setWidth, AppKit fills in the auto width).
        var x: CGFloat = 0
        for i in 0 ..< count {
            let w = segmented.width(forSegment: i)
            if point.x >= x && point.x < x + w {
                return i
            }
            x += w
        }
        return -1
    }

    // MARK: - Inline rename

    private func beginRename(at index: Int) {
        // Cancel any existing edit first.
        cancelRename()

        let segFrame = segmented.frame
        let count = segmented.segmentCount
        guard count > 0, index < count else { return }

        // Compute the segment's frame within the segmented control.
        var x: CGFloat = 0
        for i in 0 ..< index {
            x += segmented.width(forSegment: i)
        }
        let w = segmented.width(forSegment: index)
        let segmentRect = CGRect(x: segFrame.minX + x,
                                 y: segFrame.minY,
                                 width: w,
                                 height: segFrame.height)

        // Inset slightly so the field sits neatly inside the segment.
        let fieldRect = segmentRect.insetBy(dx: 4, dy: 2)

        let field = RenameTextField(frame: fieldRect)
        field.stringValue = currentManualTitle?(index) ?? ""
        field.font = segmented.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        field.alignment = .center
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.onCommit = { [weak self] in self?.commitRename() }
        field.onCancel = { [weak self] in self?.cancelRename() }

        addSubview(field)
        NSLayoutConstraint.activate([
            field.centerXAnchor.constraint(equalTo: leadingAnchor, constant: segmentRect.midX),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: fieldRect.width),
            field.heightAnchor.constraint(equalToConstant: fieldRect.height),
        ])

        editingField = field
        editingIndex = index
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func commitRename() {
        guard let field = editingField, editingIndex >= 0 else { return }
        let newName = field.stringValue
        let idx = editingIndex
        // Nil the closures before teardown so the blur from resign-first-responder
        // does not trigger a second commit call.
        field.onCommit = nil
        field.onCancel = nil
        window?.makeFirstResponder(nil)
        removeEditingField()
        onRenameTab?(idx, newName)
    }

    private func cancelRename() {
        // Nil the closures on the field before resigning so that the blur-triggered
        // `controlTextDidEndEditing` does not fire `onCommit` during teardown.
        editingField?.onCommit = nil
        editingField?.onCancel = nil
        // Resign first responder (synchronous) so the field loses focus, then remove it.
        if editingField != nil {
            window?.makeFirstResponder(nil)
        }
        removeEditingField()
    }

    private func removeEditingField() {
        editingField?.removeFromSuperview()
        editingField = nil
        editingIndex = -1
    }
}

// MARK: - RenameTextField

/// A lightweight `NSTextField` subclass that fires closures on Enter and Esc.
private final class RenameTextField: NSTextField, NSTextFieldDelegate {

    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // Intercept Enter and Esc before AppKit handles them.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // Return, numpad Enter
            onCommit?()
        case 53:       // Escape
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    // Commit on blur (e.g. clicking elsewhere).
    func controlTextDidEndEditing(_ obj: Notification) {
        // Only fire commit if we're still "live" (cancel clears onCommit first).
        onCommit?()
    }
}
