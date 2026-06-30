import AppKit

// MARK: - SidebarView

/// A vertical list of projects with select, add, and pin callbacks.
///
/// Owns an `NSTableView` (view-based, single column) inside an `NSScrollView`,
/// plus an "Add Project" button anchored at the bottom.  The view is dumb —
/// it takes plain display data in and reports user actions out via closures.
@MainActor
final class SidebarView: NSView {

    // MARK: - Callbacks

    /// Called with the row index when the user clicks a project row.
    var onSelect: ((Int) -> Void)?

    /// Called when the user clicks the "+" Add Project button.
    var onAddProject: (() -> Void)?

    /// Called with the row index when the user clicks the pin button on a row.
    var onTogglePin: ((Int) -> Void)?

    // MARK: - Private state

    private var projects: [(name: String, isPinned: Bool)] = []
    private var selectedIndex: Int = -1

    // MARK: - Subviews

    private let scrollView: NSScrollView
    private let tableView: NSTableView
    private let addButton: NSButton

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        tableView = NSTableView()
        scrollView = NSScrollView()
        addButton = NSButton(title: "+", target: nil, action: nil)

        super.init(frame: frameRect)

        setupTableView()
        setupAddButton()
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // MARK: - Setup

    private func setupTableView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProjectColumn"))
        column.minWidth = 160
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
    }

    private func setupAddButton() {
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        addButton.target = self
        addButton.action = #selector(addButtonClicked(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)
    }

    private func setupLayout() {
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -4),

            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Update

    /// True while `update()` is programmatically setting the selection, so the
    /// resulting `tableViewSelectionDidChange` doesn't re-fire `onSelect` and
    /// loop back through the owner's refresh.
    private var isUpdating = false

    /// Replaces the displayed project list and highlighted selection.
    func update(projects: [(name: String, isPinned: Bool)], selectedIndex: Int) {
        isUpdating = true
        defer { isUpdating = false }
        self.projects = projects
        self.selectedIndex = selectedIndex
        tableView.reloadData()
        if projects.indices.contains(selectedIndex) {
            let indexSet = IndexSet(integer: selectedIndex)
            tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: - Actions

    @objc private func addButtonClicked(_: Any?) {
        onAddProject?()
    }

    @objc private func pinButtonClicked(_ sender: NSButton) {
        let row = sender.tag
        guard projects.indices.contains(row) else { return }
        onTogglePin?(row)
    }
}

// MARK: - NSTableViewDataSource

extension SidebarView: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int {
        projects.count
    }
}

// MARK: - NSTableViewDelegate

extension SidebarView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ProjectCell")
        let cellView: ProjectCellView
        if let recycled = tableView.makeView(withIdentifier: identifier, owner: nil) as? ProjectCellView {
            cellView = recycled
        } else {
            cellView = ProjectCellView()
            cellView.identifier = identifier
        }
        let project = projects[row]
        cellView.configure(name: project.name, isPinned: project.isPinned, row: row, target: self, action: #selector(pinButtonClicked(_:)))
        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating else { return }  // ignore programmatic selection from update()
        guard let tv = notification.object as? NSTableView else { return }
        let row = tv.selectedRow
        guard row >= 0 else { return }
        onSelect?(row)
    }
}

// MARK: - ProjectCellView

/// A single row cell: project name label on the left, pin toggle button on the right.
private final class ProjectCellView: NSTableCellView {

    private let nameLabel: NSTextField
    private let pinButton: NSButton

    override init(frame frameRect: NSRect) {
        nameLabel = NSTextField(labelWithString: "")
        pinButton = NSButton(title: "", target: nil, action: nil)

        super.init(frame: frameRect)

        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pinButton)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -4),

            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 20),
            pinButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func configure(name: String, isPinned: Bool, row: Int, target: AnyObject, action: Selector) {
        nameLabel.stringValue = name

        let symbolName = isPinned ? "pin.fill" : "pin"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: isPinned ? "Pinned" : "Pin") {
            pinButton.image = image
        } else {
            pinButton.title = isPinned ? "📌" : "◌"
        }

        pinButton.tag = row
        pinButton.target = target
        pinButton.action = action
    }
}
