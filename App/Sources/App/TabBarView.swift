import AppKit
import ZettyCore

// MARK: - TabBarView

/// A horizontal strip of clickable tab items representing the open tabs.
///
/// Each tab item shows a title label and a × close button.  Changes are reported
/// back to the owner via the `onSelect`, `onCloseTab`, `onNewTab`, and
/// `onRenameTab` closures.  The tab *model* lives in `ZettyCore.TabList`;
/// this view only renders it.
///
/// Double-clicking a tab shows a temporary `NSTextField` overlay so the user
/// can rename the tab inline.  Committing (Enter / blur) fires
/// `onRenameTab(index, newName)`.  Escaping cancels without a callback.
@MainActor
final class TabBarView: NSView {

    // MARK: - Callbacks

    /// Called with the tab index whenever the user clicks a tab body.
    var onSelect: ((Int) -> Void)?

    /// Called when the user wants to close a tab (× button).
    var onCloseTab: ((Int) -> Void)?

    /// Called when the user wants to add a new tab (+ button).
    var onNewTab: (() -> Void)?

    /// Called when the user commits a rename.  `newName` is the raw text; pass
    /// `""` to clear `manualTitle` (revert to auto).
    var onRenameTab: ((Int, String) -> Void)?

    /// Supplies the RAW manual title for a tab index (nil/empty when auto-named),
    /// so the rename field pre-fills with the user's own name rather than the
    /// rendered auto label (which would otherwise freeze the auto name on commit).
    var currentManualTitle: ((Int) -> String?)?

    /// Called when the user clicks the sidebar-toggle button.
    var onToggleSidebar: (() -> Void)?

    /// Called when a drag-reorder finishes: move the tab at `from` to `to`.
    var onMoveTab: ((Int, Int) -> Void)?

    // MARK: - Private subviews

    private let sidebarButton: NSButton
    private let stackView: NSStackView
    private let addButton: NSButton

    // MARK: - Inline-edit state

    /// The transient field shown while the user is renaming a tab.
    private var editingField: RenameTextField?

    /// Index of the tab currently being edited (–1 when none).
    private var editingIndex: Int = -1

    // MARK: - Tab item tracking

    private var tabItems: [TabItemView] = []

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        sidebarButton = NSButton(title: "", target: nil, action: nil)
        sidebarButton.bezelStyle = .inline
        sidebarButton.isBordered = false
        sidebarButton.imagePosition = .imageOnly
        sidebarButton.translatesAutoresizingMaskIntoConstraints = false

        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.distribution = .fillEqually
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addButton = NSButton(title: "+", target: nil, action: nil)
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = ZTheme.current.bg0Color.cgColor
        styleAddButton()
        styleSidebarButton()

        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarButtonClicked(_:))
        addButton.target = self
        addButton.action = #selector(addButtonClicked(_:))

        addSubview(sidebarButton)
        addSubview(stackView)
        addSubview(addButton)

        NSLayoutConstraint.activate([
            sidebarButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: 22),
            sidebarButton.heightAnchor.constraint(equalToConstant: 22),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyPositionalLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// Which window side the sidebar sits on. The toggle button hugs the
    /// sidebar's edge of the tab bar and its symbol matches the side.
    var sidebarPosition: SidebarPosition = .left {
        didSet {
            guard oldValue != sidebarPosition else { return }
            applyPositionalLayout()
            styleSidebarButton()
        }
    }

    /// Constraints that depend on `sidebarPosition` (swapped when it changes).
    private var positionalConstraints: [NSLayoutConstraint] = []

    /// Pins `[sidebar-toggle] [tabs] [+]` left-to-right, mirrored when the
    /// sidebar is on the right so the toggle stays next to the sidebar.
    private func applyPositionalLayout() {
        NSLayoutConstraint.deactivate(positionalConstraints)
        switch sidebarPosition {
        case .left:
            positionalConstraints = [
                sidebarButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                stackView.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 6),
                addButton.leadingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: 4),
                addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            ]
        case .right:
            positionalConstraints = [
                stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                addButton.leadingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: 4),
                addButton.trailingAnchor.constraint(lessThanOrEqualTo: sidebarButton.leadingAnchor, constant: -6),
                sidebarButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ]
        }
        NSLayoutConstraint.activate(positionalConstraints)
    }

    // MARK: - Update

    /// Rebuilds tab items from `titles` and marks `selectedIndex` as selected.
    /// `icons` (parallel to `titles`, padded with nil) show an agent logo in
    /// the pill when one is bundled.
    func update(titles: [String], icons: [NSImage?] = [], selectedIndex: Int) {
        // Live agents retitle their tabs every second; rebuilding the pills
        // mid-drag would destroy the one being dragged and kill the gesture.
        // Skip refreshes until the drag commits (which triggers one anyway).
        guard !isReordering else { return }
        cancelRename()

        // Remove old items.
        for item in tabItems {
            stackView.removeArrangedSubview(item)
            item.removeFromSuperview()
        }
        tabItems.removeAll()

        // Build new items.
        for (index, title) in titles.enumerated() {
            let icon = index < icons.count ? icons[index] : nil
            let item = TabItemView(title: title, icon: icon, index: index, isSelected: index == selectedIndex, showsClose: titles.count > 1)
            item.onSelect = { [weak self] idx in
                self?.onSelect?(idx)
            }
            item.onClose = { [weak self] idx in
                self?.onCloseTab?(idx)
            }
            item.onDoubleClick = { [weak self] idx in
                self?.beginRename(at: idx)
            }
            item.onDragMoved = { [weak self] item, location in
                self?.itemDragged(item, locationInWindow: location)
            }
            item.onDragEnded = { [weak self] item in
                self?.itemDragEnded(item)
            }
            stackView.addArrangedSubview(item)
            tabItems.append(item)
        }
    }

    // MARK: - Drag reorder

    /// The dragged tab's model index when the reorder gesture began (the pill
    /// itself keeps that index until the owner rebuilds after the commit).
    private var dragSourceIndex: Int?

    /// True while a pill is being dragged — freezes `update(...)` rebuilds.
    private var isReordering = false

    /// Live reorder: slide the dragged pill into the slot under the cursor.
    private func itemDragged(_ item: TabItemView, locationInWindow: NSPoint) {
        isReordering = true
        if dragSourceIndex == nil { dragSourceIndex = item.index }
        guard tabItems.count > 1,
              let current = tabItems.firstIndex(where: { $0 === item }) else { return }
        let x = stackView.convert(locationInWindow, from: nil).x
        let slotWidth = stackView.bounds.width / CGFloat(tabItems.count)
        guard slotWidth > 0 else { return }
        let slot = max(0, min(tabItems.count - 1, Int(x / slotWidth)))
        guard slot != current else { return }
        stackView.removeArrangedSubview(item)
        stackView.insertArrangedSubview(item, at: slot)
        tabItems.remove(at: current)
        tabItems.insert(item, at: slot)
    }

    /// Commit: tell the owner where the dragged tab ended up.
    private func itemDragEnded(_ item: TabItemView) {
        isReordering = false
        defer { dragSourceIndex = nil }
        guard let source = dragSourceIndex,
              let destination = tabItems.firstIndex(where: { $0 === item }),
              source != destination else { return }
        onMoveTab?(source, destination)
    }

    /// Applies theme-dependent styling to the sidebar-toggle button; the
    /// symbol mirrors the sidebar's window side.
    private func styleSidebarButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let symbol = sidebarPosition == .left ? "sidebar.left" : "sidebar.right"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle sidebar")?
            .withSymbolConfiguration(config) {
            sidebarButton.image = image
            sidebarButton.imageScaling = .scaleProportionallyUpOrDown
            sidebarButton.contentTintColor = ZTheme.current.fgColor
        } else {
            sidebarButton.attributedTitle = NSAttributedString(
                string: "☰",
                attributes: [
                    .font: ZTheme.monoFont(size: 15),
                    .foregroundColor: ZTheme.current.fgColor,
                ]
            )
        }
        sidebarButton.toolTip = "Toggle sidebar (⌘B)"
    }

    /// Applies theme-dependent styling to the `+` button (re-callable on scheme change).
    private func styleAddButton() {
        addButton.attributedTitle = NSAttributedString(
            string: "+",
            attributes: [
                .font: ZTheme.monoFont(size: 15, weight: .regular),
                .foregroundColor: ZTheme.current.fg2Color,
            ]
        )
    }

    /// Re-applies the active theme to the bar background and `+` button. Tab
    /// items recolor when the caller reloads via `update(...)`.
    func applyTheme() {
        layer?.backgroundColor = ZTheme.current.bg0Color.cgColor
        styleAddButton()
        styleSidebarButton()
    }

    // MARK: - Actions

    @objc private func sidebarButtonClicked(_: Any?) {
        onToggleSidebar?()
    }

    @objc private func addButtonClicked(_: Any?) {
        onNewTab?()
    }

    // MARK: - Inline rename

    /// Opens the inline rename editor programmatically — the prefix-key
    /// layer's rename-tab command (prefix + ,) targets the active tab this
    /// way; double-click stays the mouse path.
    func beginRenameProgrammatically(at index: Int) {
        beginRename(at: index)
    }

    private func beginRename(at index: Int) {
        cancelRename()

        guard tabItems.indices.contains(index) else { return }
        let item = tabItems[index]

        // Force a layout pass so labelFrame is current before we read it.
        item.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()

        // Convert the item's label frame to self's coordinate space.
        let labelFrameInItem = item.labelFrame
        let labelFrameInSelf = convert(labelFrameInItem, from: item)

        let fieldRect = labelFrameInSelf.insetBy(dx: 4, dy: 2)

        let field = RenameTextField(frame: fieldRect)
        field.stringValue = currentManualTitle?(index) ?? ""
        field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        field.alignment = .center
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.onCommit = { [weak self] in self?.commitRename() }
        field.onCancel = { [weak self] in self?.cancelRename() }

        addSubview(field)
        NSLayoutConstraint.activate([
            field.centerXAnchor.constraint(equalTo: leadingAnchor, constant: labelFrameInSelf.midX),
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

// MARK: - TabItemView

/// A single tab pill showing a title and a × close button.
@MainActor
private final class TabItemView: NSView {

    // MARK: Constants

    private static let minWidth: CGFloat = 80
    private static let maxWidth: CGFloat = 200
    private static let closeButtonSize: CGFloat = 16

    // MARK: Callbacks

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    /// Horizontal drag beyond the click slop — reorder gesture in progress
    /// (location in window coordinates) / finished.
    var onDragMoved: ((TabItemView, NSPoint) -> Void)?
    var onDragEnded: ((TabItemView) -> Void)?

    // MARK: Subviews

    private let statusDot: NSView
    /// Agent logo shown before the title when one is bundled (see
    /// TerminalViewController.agentIcon); nil → the name prefix is in the text.
    private let iconView: NSImageView?
    private let titleLabel: NSTextField
    private let closeButton: NSButton
    /// Accent bar pinned to the top edge, shown only when selected (handoff).
    private let topBar = CALayer()

    // MARK: State

    let index: Int
    private var isSelected: Bool {
        didSet { updateAppearance() }
    }

    /// The frame of the title label in this view's coordinate space (used by
    /// TabBarView to position the rename overlay accurately).
    var labelFrame: CGRect {
        titleLabel.frame
    }

    // MARK: Init

    init(title: String, icon: NSImage? = nil, index: Int, isSelected: Bool, showsClose: Bool) {
        self.index = index
        self.isSelected = isSelected

        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        if let icon {
            let view = NSImageView(image: icon)
            view.imageScaling = .scaleProportionallyDown
            view.translatesAutoresizingMaskIntoConstraints = false
            iconView = view
        } else {
            iconView = nil
        }

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.lineBreakMode = .byTruncatingTail
        // High (not required): pills size to their title up to maxWidth, but
        // still compress toward minWidth when the bar genuinely runs out of
        // room (the container's required trailing constraint wins). Low would
        // let the stack squeeze every pill to minWidth even with free space.
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // × close button — use the system xmark symbol when available.
        if #available(macOS 11.0, *),
           let xmark = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab") {
            closeButton = NSButton(image: xmark, target: nil, action: nil)
            closeButton.imageScaling = .scaleProportionallyDown
        } else {
            closeButton = NSButton(title: "×", target: nil, action: nil)
        }
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.contentTintColor = ZTheme.current.fg3Color
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        wantsLayer = true

        topBar.backgroundColor = ZTheme.current.accentColor.cgColor
        topBar.cornerRadius = 1
        layer?.addSublayer(topBar)

        addSubview(statusDot)
        if let iconView { addSubview(iconView) }
        addSubview(titleLabel)

        var constraints: [NSLayoutConstraint] = [
            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minWidth),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
        ]

        if let iconView {
            constraints += [
                iconView.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 14),
                iconView.heightAnchor.constraint(equalToConstant: 14),
                titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            ]
        } else {
            constraints.append(titleLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8))
        }

        if showsClose {
            // Only show a × when there are 2+ tabs (the last tab can't be closed).
            addSubview(closeButton)
            closeButton.target = self
            closeButton.action = #selector(closeClicked(_:))
            constraints += [
                titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: Self.closeButtonSize),
                closeButton.heightAnchor.constraint(equalToConstant: Self.closeButtonSize),
            ]
        } else {
            constraints.append(titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10))
        }
        NSLayoutConstraint.activate(constraints)

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        // Accent bar spans the tab width, hugging the top edge.
        topBar.frame = CGRect(x: 10, y: 0, width: max(0, bounds.width - 20), height: 2)
    }

    // MARK: Appearance

    private func updateAppearance() {
        let theme = ZTheme.current
        if isSelected {
            layer?.backgroundColor = theme.bg1Color.cgColor
            statusDot.layer?.backgroundColor = theme.accentColor.cgColor
            titleLabel.font = ZTheme.monoFont(size: 12.5, weight: .semibold)
            titleLabel.textColor = theme.fgColor
            topBar.isHidden = false
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            statusDot.layer?.backgroundColor = theme.fg3Color.cgColor
            titleLabel.font = ZTheme.monoFont(size: 12.5, weight: .medium)
            titleLabel.textColor = theme.fg2Color
            topBar.isHidden = true
        }
        // Template logo tints along with the title text.
        iconView?.contentTintColor = titleLabel.textColor
    }

    // MARK: Mouse interaction

    /// True once the current press has travelled past the click slop and
    /// became a reorder drag.
    private var isDraggingToReorder = false
    private var mouseDownLocation: NSPoint = .zero

    // Selection fires on mouseUP, not down: selecting rebuilds the whole tab
    // bar, which would orphan this pill mid-gesture and kill drag-to-reorder.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(index)
            return
        }
        mouseDownLocation = event.locationInWindow
        isDraggingToReorder = false
    }

    override func mouseDragged(with event: NSEvent) {
        if !isDraggingToReorder,
           abs(event.locationInWindow.x - mouseDownLocation.x) > 4 {
            isDraggingToReorder = true
        }
        guard isDraggingToReorder else { return }
        onDragMoved?(self, event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingToReorder {
            isDraggingToReorder = false
            onDragEnded?(self)
        } else if event.clickCount == 1 {
            onSelect?(index)
        }
    }

    @objc private func closeClicked(_: Any?) {
        onClose?(index)
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
