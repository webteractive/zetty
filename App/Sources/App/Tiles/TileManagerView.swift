import AppKit
import ZettyCore

/// One saved tile view as the manager lists it.
struct TileManagerRow: Equatable {
    let id: UUID
    let name: String
    let root: TileNode
    let capacity: Int
    let attached: Int
    /// A pill in the strip.
    let isOpen: Bool
    /// The view the grid is showing right now.
    let isShowing: Bool
}

// MARK: - TileManagerView

/// The tile manager: every saved tile view, with Open, Rename, Duplicate and
/// Delete.
///
/// Until this existed a view could be made but never removed — closing its pill
/// keeps it in the library, deliberately, so an arrangement is never lost by
/// accident — and the library only grew. Deleting lives here, confirmed, and in
/// `zetty tiles delete`, which share `TerminalViewController.deleteTileProfile`
/// so the two cannot disagree about what deleting closes.
///
/// It owns no state: every row comes from `rows()`, and the controller calls
/// `reload()` whenever the library or the open set changes.
///
/// One view, two hosts, exactly like `SessionsView`: the bottom drawer and
/// `TileManagerWindowController` both embed it, and `zetty-tile-manager-view`
/// says which. The mode button flips it.
@MainActor
final class TileManagerView: NSView {

    private enum Column: String, CaseIterable {
        case shape = ""
        case name = "NAME"
        case slots = "SLOTS"
        case state = "STATE"
        case actions = " "

        var width: CGFloat {
            switch self {
            case .shape: return 36
            case .name: return 220
            case .slots: return 70
            case .state: return 90
            case .actions: return 36
            }
        }
    }

    private let rowsProvider: () -> [TileManagerRow]
    private let onOpen: (UUID) -> Void
    private let onRename: (UUID, String) throws -> Void
    private let onDuplicate: (UUID) throws -> UUID?
    private let onDelete: (UUID) -> Void
    private let onNew: () -> UUID?
    private let onToggleMode: () -> Void
    /// Which host this instance is in. Decides the mode button's glyph, and
    /// whether `applyTheme` may restyle the window — in the drawer, that window
    /// is the main one, which is not this view's to paint.
    private let mode: SessionsViewMode

    private let summaryLabel = NSTextField(labelWithString: "")
    private let newButton = NSButton()
    private let modeButton = NSButton()
    private let tableView = TileManagerTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let topBorder = NSView()
    private var rows: [TileManagerRow] = []

    /// The row whose name is being edited. A reload mid-edit would destroy the
    /// field under the caret, so it waits for the edit to end.
    private var editingID: UUID?
    private var reloadPending = false

    init(mode: SessionsViewMode,
         rows: @escaping () -> [TileManagerRow],
         onOpen: @escaping (UUID) -> Void,
         onRename: @escaping (UUID, String) throws -> Void,
         onDuplicate: @escaping (UUID) throws -> UUID?,
         onDelete: @escaping (UUID) -> Void,
         onNew: @escaping () -> UUID?,
         onToggleMode: @escaping () -> Void) {
        self.mode = mode
        self.onToggleMode = onToggleMode
        self.rowsProvider = rows
        self.onOpen = onOpen
        self.onRename = onRename
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.onNew = onNew
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    private func build() {
        summaryLabel.font = ZTheme.chromeFont(size: 12)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summaryLabel)

        newButton.title = "New View"
        newButton.bezelStyle = .rounded
        newButton.controlSize = .small
        newButton.font = ZTheme.chromeFont(size: 11)
        newButton.target = self
        newButton.action = #selector(newClicked)
        newButton.toolTip = "Make a view with one slot and open it"
        newButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newButton)

        modeButton.isBordered = false
        modeButton.target = self
        modeButton.action = #selector(modeClicked)
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeButton)

        topBorder.wantsLayer = true
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.rowHeight = 30
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.onReturn = { [weak self] in self?.openSelected() }
        tableView.onDelete = { [weak self] in self?.confirmDeleteSelected() }
        for column in Column.allCases {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            item.title = column.rawValue
            item.width = column.width
            // Small minimums, as in Sessions: a column minimum propagates out
            // as width the window cannot reclaim.
            item.minWidth = column == .name ? 80 : 30
            if column == .slots { item.headerCell.alignment = .right }
            if column == .slots {
                item.headerToolTip = "Attached panes / slots in the layout"
            }
            tableView.addTableColumn(item)
        }
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.tableColumns.first { $0.identifier.rawValue == Column.name.rawValue }?
            .resizingMask = [.autoresizingMask, .userResizingMask]

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        emptyLabel.font = ZTheme.chromeFont(size: 12)
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.stringValue = "No tile views yet. New View makes one."
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        // Sessions' anatomy: a 1pt border along the top edge (the drawer's
        // seam with the terminal), then the header row, then the table.
        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            summaryLabel.centerYAnchor.constraint(equalTo: newButton.centerYAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: newButton.leadingAnchor,
                                                   constant: -8),

            newButton.topAnchor.constraint(equalTo: topBorder.bottomAnchor, constant: 6),
            newButton.trailingAnchor.constraint(equalTo: modeButton.leadingAnchor, constant: -8),

            modeButton.centerYAnchor.constraint(equalTo: newButton.centerYAnchor),
            modeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            modeButton.widthAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        applyTheme()
    }

    func applyTheme() {
        let theme = ZTheme.current
        layer?.backgroundColor = theme.bg1Color.cgColor
        topBorder.layer?.backgroundColor = theme.borderColor.cgColor
        summaryLabel.textColor = theme.fg2Color
        emptyLabel.textColor = theme.fg3Color
        tableView.backgroundColor = theme.bg1Color
        scrollView.backgroundColor = theme.bg1Color
        styleModeButton()
        if mode == .window {
            window?.appearance = theme.appearance
            window?.backgroundColor = theme.bg1Color
        }
        // Colours are baked into the cells, so an unchanged row list still has
        // to be rebuilt for the new palette.
        tableView.reloadData()
    }

    /// The same glyphs Sessions uses, so docking reads the same in both.
    private func styleModeButton() {
        let docked = mode == .drawer
        let candidates = docked
            ? ["arrow.up.left.and.arrow.down.right.square",
               "arrow.up.left.and.arrow.down.right",
               "arrow.up.forward.square"]
            : ["arrow.down.right.and.arrow.up.left.square",
               "arrow.down.right.and.arrow.up.left",
               "arrow.down.forward.square"]
        for symbol in candidates {
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            else { continue }
            modeButton.image = image
            break
        }
        modeButton.contentTintColor = ZTheme.current.fg2Color
        modeButton.toolTip = docked
            ? "Open Tile Views in its own window"
            : "Dock Tile Views to the bottom of the window"
    }

    @objc private func modeClicked() { onToggleMode() }

    // MARK: - Content

    func reload() {
        guard editingID == nil else {
            reloadPending = true
            return
        }
        reloadPending = false
        // Remembered by id: a delete or duplicate shifts every later row.
        let selected = rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow].id : nil
        let newRows = rowsProvider()
        let open = newRows.filter(\.isOpen).count
        summaryLabel.stringValue = "\(newRows.count) view\(newRows.count == 1 ? "" : "s")"
            + (open > 0 ? " · \(open) open" : "")
        emptyLabel.isHidden = !newRows.isEmpty
        guard newRows != rows else { return }
        rows = newRows
        tableView.reloadData()
        select(selected)
    }

    private func select(_ id: UUID?) {
        guard let id, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    // MARK: - Actions

    @objc private func newClicked() {
        let id = onNew()
        reload()
        select(id)
    }

    @objc private func rowDoubleClicked() {
        let index = tableView.clickedRow
        guard rows.indices.contains(index) else { return }
        onOpen(rows[index].id)
    }

    private func openSelected() {
        guard rows.indices.contains(tableView.selectedRow) else { return }
        onOpen(rows[tableView.selectedRow].id)
    }

    @objc private func actionsClicked(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let menu = NSMenu()
        for (title, action) in [("Open", #selector(openPicked(_:))),
                                ("Rename\u{2026}", #selector(renamePicked(_:))),
                                ("Duplicate", #selector(duplicatePicked(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = sender.tag
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete\u{2026}", action: #selector(deletePicked(_:)),
                                keyEquivalent: "")
        delete.target = self
        delete.tag = sender.tag
        menu.addItem(delete)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func openPicked(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag) else { return }
        onOpen(rows[sender.tag].id)
    }

    @objc private func renamePicked(_ sender: NSMenuItem) {
        beginRename(row: sender.tag)
    }

    @objc private func duplicatePicked(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag) else { return }
        do {
            let copy = try onDuplicate(rows[sender.tag].id)
            reload()
            select(copy)
        } catch {
            present(error, title: "Couldn\u{2019}t duplicate the view")
        }
    }

    @objc private func deletePicked(_ sender: NSMenuItem) {
        confirmDelete(row: sender.tag)
    }

    private func confirmDeleteSelected() {
        confirmDelete(row: tableView.selectedRow)
    }

    private func confirmDelete(row index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(row.name)\u{201D}?"
        alert.informativeText = row.isOpen
            ? "The view closes and leaves the library. The panes it shows keep running."
            : "The view leaves the library. The panes it shows keep running."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let id = row.id
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onDelete(id)
            self?.reload()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    /// Turns the row's name label into a field in place. Enter commits,
    /// Escape cancels; a refused name puts the old one back and says why.
    private func beginRename(row index: Int) {
        guard rows.indices.contains(index),
              let column = tableView.tableColumns.firstIndex(where: {
                  $0.identifier.rawValue == Column.name.rawValue }),
              let cell = tableView.view(atColumn: column, row: index, makeIfNecessary: true)
                as? TileManagerCellView,
              let field = cell.content as? NSTextField else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        editingID = rows[index].id
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func present(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        let message = error.localizedDescription
        alert.informativeText = message.prefix(1).uppercased() + message.dropFirst() + "."
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

// MARK: - Rename editing

extension TileManagerView: NSTextFieldDelegate {

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              let field = control as? NSTextField,
              let id = editingID,
              let row = rows.first(where: { $0.id == id }) else { return false }
        // Escape: put the old name back before the end-editing below commits.
        field.stringValue = row.name
        window?.makeFirstResponder(tableView)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = editingID else { return }
        field.isEditable = false
        field.isSelectable = false
        editingID = nil
        let original = rows.first { $0.id == id }?.name
        if field.stringValue != original {
            do { try onRename(id, field.stringValue) }
            catch {
                field.stringValue = original ?? field.stringValue
                present(error, title: "Couldn\u{2019}t rename the view")
            }
        }
        reload()
        window?.makeFirstResponder(tableView)
    }
}

// MARK: - Table

extension TileManagerView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// Selection fills `bg3`, never the system accent — accent means focus and
    /// active, and a saturated selection block would read as the showing view.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TileManagerRowView()
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard rows.indices.contains(index),
              let raw = tableColumn?.identifier.rawValue,
              let column = Column(rawValue: raw) else { return nil }
        let row = rows[index]
        let theme = ZTheme.current

        switch column {
        case .shape:
            let image = NSImageView(image: TileShapeImage.make(for: row.root, size: 18))
            image.contentTintColor = row.isShowing ? theme.accentColor : theme.fg2Color
            image.imageScaling = .scaleProportionallyDown
            return TileManagerCellView(content: image, centred: true)
        case .actions:
            let button = NSButton(title: "\u{22EF}", target: self, action: #selector(actionsClicked(_:)))
            button.isBordered = false
            button.font = ZTheme.chromeFont(size: 13, weight: .bold)
            button.contentTintColor = theme.fg2Color
            button.tag = index
            button.toolTip = "Actions for this view"
            return TileManagerCellView(content: button, centred: true)
        case .name, .slots, .state:
            let label = NSTextField(labelWithString: "")
            label.font = ZTheme.chromeFont(size: 12, weight: column == .name && row.isShowing ? .semibold : .regular)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            switch column {
            case .name:
                label.stringValue = row.name
                label.textColor = theme.fgColor
            case .slots:
                label.stringValue = "\(row.attached)/\(row.capacity)"
                label.textColor = theme.fg2Color
                label.alignment = .right
            default:
                label.stringValue = row.isShowing ? "Showing" : (row.isOpen ? "Open" : "")
                label.textColor = row.isShowing ? theme.accentColor : theme.fg2Color
            }
            return TileManagerCellView(content: label, centred: false)
        }
    }
}

// MARK: - Pieces

/// A cell with its content vertically centred — see `SessionCellView` for why
/// a bare field returned from `viewFor` looks misaligned.
@MainActor
private final class TileManagerCellView: NSView {
    let content: NSView

    init(content: NSView, centred: Bool) {
        self.content = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        var constraints = [content.centerYAnchor.constraint(equalTo: centerYAnchor)]
        if centred {
            constraints.append(content.centerXAnchor.constraint(equalTo: centerXAnchor))
        } else {
            constraints += [
                content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

@MainActor
private final class TileManagerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        ZTheme.current.bg3Color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// Return opens and Delete deletes the selected view, the keys a list of
/// things in a Mac window answers to.
@MainActor
private final class TileManagerTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()                       // Return, keypad Enter
        case 51, 117: onDelete?()                      // Delete, forward delete
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - TileManagerWindowController

/// The manager's window: a thin host for `TileManagerView`, like the Sessions
/// window is for `SessionsView`.
@MainActor
final class TileManagerWindowController: NSWindowController {

    private let manager: TileManagerView

    init(manager: TileManagerView) {
        self.manager = manager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Tile Views"
        window.isReleasedWhenClosed = false
        window.appearance = ZTheme.current.appearance
        window.backgroundColor = ZTheme.current.bg1Color
        window.contentMinSize = NSSize(width: 380, height: 200)
        super.init(window: window)

        if let content = window.contentView {
            content.addSubview(manager)
            NSLayoutConstraint.activate([
                manager.topAnchor.constraint(equalTo: content.topAnchor),
                manager.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                manager.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                manager.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show() {
        manager.reload()
        manager.applyTheme()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
