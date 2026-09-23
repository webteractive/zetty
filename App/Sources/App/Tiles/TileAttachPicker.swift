import AppKit
import ZettyCore

/// A scrim + centred panel listing every pane — plus a fresh session per
/// project — fuzzy-filtered, for attaching one into a tile slot.
///
/// Deliberately shaped like `CommandPaletteView` — same anatomy, same four key
/// commands — so it behaves the way the palette already taught.
@MainActor
final class TileAttachPicker: NSView {

    /// What picking a row does. The picker stays dumb — it ranks labels and
    /// hands the action back; the controller owns every consequence.
    enum Action {
        /// Attach an existing tab.
        case attach(TileSlot)
        /// Mint a fresh tab in this project and attach that.
        case newSession(projectIndex: Int)
    }

    struct Candidate {
        let label: String
        let detail: String
        let action: Action
    }

    private let candidates: [Candidate]
    private var filtered: [Int]
    private var selection = 0
    private let onPick: (Action?) -> Void

    private let panel = NSView()
    private let field = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing to attach.")

    init(candidates: [Candidate], onPick: @escaping (Action?) -> Void) {
        self.candidates = candidates
        self.filtered = Array(candidates.indices)
        self.onPick = onPick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func present(in container: NSView) {
        container.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: container.topAnchor),
            leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window?.makeFirstResponder(field)
    }

    // MARK: - Build

    private func build() {
        let theme = ZTheme.current

        panel.wantsLayer = true
        panel.layer?.backgroundColor = theme.bg2Color.cgColor
        panel.layer?.cornerRadius = 10
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = theme.borderColor.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        field.font = ZTheme.chromeFont(size: 13)
        field.placeholderString = "Attach a pane or start a new session\u{2026}"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = theme.fgColor
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(field)

        tableView.headerView = nil
        tableView.backgroundColor = theme.bg2Color
        tableView.rowHeight = 26
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrollView)

        emptyLabel.font = ZTheme.chromeFont(size: 12)
        emptyLabel.textColor = theme.fg3Color
        emptyLabel.alignment = .center
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.isHidden = !candidates.isEmpty
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(emptyLabel)

        // EVERY size here is a PREFERENCE. 750 is inside the band AppKit folds
        // into the window's minimum content size, so .defaultHigh would grow
        // the window on open — exactly how the command palette shipped.
        let width = panel.widthAnchor.constraint(equalToConstant: 520)
        let height = scrollView.heightAnchor.constraint(equalToConstant: 320)
        let top = panel.topAnchor.constraint(equalTo: topAnchor, constant: 96)
        for constraint in [width, height, top] { constraint.priority = .defaultLow }

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            panel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            width, top,

            field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),

            scrollView.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            height,

            emptyLabel.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: panel.leadingAnchor,
                                                constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor,
                                                 constant: -12),
        ])
    }

    // MARK: - Filtering

    /// The same matcher the command palette uses, so filtering behaves the way
    /// people already expect here.
    private func refilter(_ query: String) {
        filtered = CommandSearch.rank(query: query, labels: candidates.map(\.label))
        selection = 0
        tableView.reloadData()
        emptyLabel.isHidden = !filtered.isEmpty
        if !filtered.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = min(max(selection + delta, 0), filtered.count - 1)
        tableView.selectRowIndexes([selection], byExtendingSelection: false)
        tableView.scrollRowToVisible(selection)
    }

    private func commit() {
        guard filtered.indices.contains(selection) else { return close(nil) }
        close(candidates[filtered[selection]].action)
    }

    func close(_ action: Action?) {
        removeFromSuperview()
        onPick(action)
    }

    @objc private func rowDoubleClicked() {
        selection = max(0, tableView.clickedRow)
        commit()
    }

    // MARK: - Scrim click closes

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(point) { close(nil) }
    }
}

// MARK: - Table

extension TileAttachPicker: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in _: NSTableView) -> Int { filtered.count }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let candidate = candidates[filtered[row]]
        let theme = ZTheme.current

        let container = NSView()
        let label = NSTextField(labelWithString: candidate.label)
        label.font = ZTheme.chromeFont(size: 12)
        label.textColor = theme.fgColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let detail = NSTextField(labelWithString: candidate.detail)
        detail.font = ZTheme.chromeFont(size: 11)
        detail.textColor = theme.fg3Color
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(detail)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor,
                                            constant: -8),
            detail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            detail.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    func tableViewSelectionDidChange(_: Notification) {
        if tableView.selectedRow >= 0 { selection = tableView.selectedRow }
    }
}

// MARK: - Field

extension TileAttachPicker: NSTextFieldDelegate {

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        refilter(field.stringValue)
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.insertNewline(_:)): commit(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(nil); return true
        default: return false
        }
    }
}
