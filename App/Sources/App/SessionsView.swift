import AppKit
import ZettyCore

// MARK: - SessionsView

/// Every zmx session Zetty spawned: what owns it, what it is running, what it
/// is costing, and the actions to deal with it — grouped under a header row
/// per project, whose moon (Hibernate) is also an item on each of its
/// sessions' ⋮ menus.
///
/// One view, two hosts — the bottom drawer and the detached window both embed
/// this. A second implementation for the drawer would drift from this one
/// within a release.
///
/// It owns no timer: `SessionSampler` rides the foreground probe's existing
/// sweep and calls back.
@MainActor
final class SessionsView: NSView {

    private enum Column: String, CaseIterable {
        /// First, so a row's verbs sit beside its name rather than past the
        /// numbers at the far edge of a wide drawer.
        case actions = ""
        case session = "SESSION"
        case pane = "PANE"
        case running = "RUNNING"
        case cpu = "CPU"
        // "RAM", not "SESSION RSS". The distinction it guarded is real — this
        // measures the session's own processes, not what the pane costs Zetty
        // — but the row IS a session, so nobody was going to read it the other
        // way, and the header was jargon for a number every task manager calls
        // memory. The precision lives in the column's tooltip instead.
        case rss = "RAM"

        var width: CGFloat {
            switch self {
            case .session: return 150
            case .pane: return 210
            case .running: return 110
            case .cpu: return 70
            case .rss: return 100
            case .actions: return 34
            }
        }
    }

    private let sampler: SessionSampler
    private let groupsProvider: () -> [TaskGroup]
    private let footprintProvider: () -> Int64?
    private let onReveal: (TaskRow) -> Void
    private let onInterrupt: (TaskRow) -> Void
    private let onKill: (TaskRow) -> Void
    private let onProjectAction: (UUID) -> Void
    private let onToggleMode: () -> Void
    private let onClose: () -> Void

    private let summaryLabel = NSTextField(labelWithString: "")
    private let modeButton = NSButton()
    /// Drawer only: the detached window has its own title-bar close, and a
    /// second one inside it would be two controls for one action.
    private let closeButton = NSButton()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let topBorder = NSView()
    /// What the table shows, one entry per table row: each group's header
    /// followed by its sessions.
    private var entries: [Entry] = []

    private enum Entry: Equatable {
        case group(TaskGroup)
        case session(TaskRow)

        /// Identity for in-place updates and selection: a header by its owner,
        /// a session by its name.
        var key: String {
            switch self {
            case .group(let group):
                switch group.owner {
                case .project(let id): return "group:\(id.uuidString)"
                case .orphaned: return "group:orphaned"
                }
            case .session(let row): return row.session
            }
        }

        var session: TaskRow? {
            if case .session(let row) = self { return row }
            return nil
        }
    }

    private var sessionRows: [TaskRow] { entries.compactMap(\.session) }

    private func session(at index: Int) -> TaskRow? {
        entries.indices.contains(index) ? entries[index].session : nil
    }

    /// Which host this instance is in, deciding only the mode button's glyph.
    private let mode: SessionsViewMode

    init(mode: SessionsViewMode,
         sampler: SessionSampler,
         groupsProvider: @escaping () -> [TaskGroup],
         footprintProvider: @escaping () -> Int64?,
         onReveal: @escaping (TaskRow) -> Void,
         onInterrupt: @escaping (TaskRow) -> Void,
         onKill: @escaping (TaskRow) -> Void,
         onProjectAction: @escaping (UUID) -> Void,
         onToggleMode: @escaping () -> Void,
         onClose: @escaping () -> Void = {}) {
        self.mode = mode
        self.sampler = sampler
        self.groupsProvider = groupsProvider
        self.footprintProvider = footprintProvider
        self.onReveal = onReveal
        self.onInterrupt = onInterrupt
        self.onKill = onKill
        self.onProjectAction = onProjectAction
        self.onToggleMode = onToggleMode
        self.onClose = onClose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    private func build() {
        let theme = ZTheme.current
        layer?.backgroundColor = theme.bg1Color.cgColor

        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = theme.borderColor.cgColor
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        summaryLabel.font = ZTheme.chromeFont(size: 12)
        summaryLabel.textColor = theme.fg2Color
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summaryLabel)

        modeButton.isBordered = false
        modeButton.target = self
        modeButton.action = #selector(modeClicked)
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        styleModeButton()
        addSubview(modeButton)

        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        closeButton.toolTip = "Close Sessions (⌘J)"
        closeButton.contentTintColor = theme.fg2Color
        closeButton.isHidden = mode != .drawer
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = theme.bg1Color
        tableView.gridStyleMask = []
        tableView.rowHeight = 26
        tableView.allowsMultipleSelection = false
        // A floating header would stack over the rows in a short drawer.
        tableView.floatsGroupRows = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        for column in Column.allCases {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            item.title = column.rawValue
            item.width = column.width
            if column == .cpu || column == .rss {
                // The cells were right-aligned but the headers were not, which
                // reads as the column itself being misaligned.
                item.headerCell.alignment = .right
            }
            if column == .rss {
                item.headerToolTip = "Resident memory of this session's own processes. "
                    + "Not what the pane costs Zetty — per-pane GPU memory lives inside "
                    + "libghostty and cannot be measured from here."
            }
            // A column minimum propagates outward as width the window cannot
            // reclaim; keep it small and let cells truncate.
            item.minWidth = 34
            tableView.addTableColumn(item)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.bg1Color
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        emptyLabel.font = ZTheme.chromeFont(size: 12)
        emptyLabel.textColor = theme.fg3Color
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            summaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeButton.leadingAnchor,
                                                   constant: -8),

            modeButton.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 22),

            closeButton.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        // Beside the close button in the drawer; at the edge in the window,
        // where the close button is hidden.
        (mode == .drawer
            ? modeButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4)
            : modeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ).isActive = true
    }

    private func styleModeButton() {
        let docked = mode == .drawer
        // Two arrows inside a square, echoing break-into-tab's
        // `arrow.up.forward.square`: the square is the destination and the
        // arrows say which way it is going. Tried in order because the
        // `.square` variants are newer, and a nil image leaves a blank button.
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
            ? "Open Sessions in its own window"
            : "Dock Sessions to the bottom of the window"
    }

    // MARK: - Content

    /// Fired after every sampler tick, so a host can track the load too — the
    /// status bar's pill uses it for its dot.
    var onTick: (() -> Void)?

    /// Starts or stops aggregation. The `ps` sweep belongs to the foreground
    /// probe and runs regardless; this only decides whether it is consumed.
    ///
    /// Claiming `sampler.onUpdate` here rather than at construction is what
    /// keeps one sampler serving whichever host is on screen: only the active
    /// view is subscribed, so a detached window and a drawer can never both
    /// redraw from the same tick.
    func setActive(_ active: Bool) {
        sampler.isActive = active
        if active {
            sampler.onUpdate = { [weak self] in
                self?.reload()
                self?.onTick?()
            }
            reload()
        } else {
            sampler.onUpdate = nil
        }
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
        closeButton.contentTintColor = theme.fg2Color
        tableView.reloadData()
    }

    func reload() {
        // Captured before `entries` is replaced: `selectedRow` indexes the list
        // currently on screen.
        //
        // Remembered BY SESSION, never by index: the list re-sorts by CPU every
        // few seconds, so restoring an index would quietly move the selection
        // to whichever session took that slot — and the selection is what the
        // row actions act on.
        let previouslySelected = session(at: tableView.selectedRow)?.session

        let newEntries = groupsProvider().flatMap { group in
            [Entry.group(group)] + group.rows.map(Entry.session)
        }
        let sameRows = updateInPlace(newEntries)
        if !sameRows { entries = newEntries }

        let rows = sessionRows
        let footprint = footprintProvider().map(ByteFormat.short) ?? "unknown"
        let sessions = rows.count
        let orphans = rows.filter(\.isOrphan).count
        var summary = "Zetty · \(footprint) · \(sessions) session\(sessions == 1 ? "" : "s")"
        if orphans > 0 { summary += " · \(orphans) orphaned" }
        summaryLabel.stringValue = summary

        emptyLabel.stringValue = rows.isEmpty
            ? "No sessions. Panes run inside zmx sessions only when preserve-sessions is on."
            : ""
        emptyLabel.isHidden = !rows.isEmpty

        // Cells were refreshed without disturbing the table, so the selection
        // was never touched; nothing else to do.
        guard !sameRows else { return }

        tableView.reloadData()
        if let previouslySelected,
           let restored = entries.firstIndex(where: { $0.session?.session == previouslySelected }) {
            tableView.selectRowIndexes(IndexSet(integer: restored), byExtendingSelection: false)
        }
    }

    /// Updates the cells of an unchanged row list WITHOUT `reloadData`.
    ///
    /// This is what actually keeps a row selected. `reloadData` destroys and
    /// rebuilds every row view, and saving and restoring the selection around
    /// it is not enough: the highlight flickers off and a row can lose its view
    /// mid-interaction. The sampler ticks every few seconds and the session
    /// list is usually identical between ticks, so the common case should touch
    /// nothing but the text.
    ///
    /// The same shape `TabBarView` uses for its pills, and for the same reason.
    private func updateInPlace(_ newEntries: [Entry]) -> Bool {
        guard newEntries.map(\.key) == entries.map(\.key) else { return false }
        entries = newEntries
        // Row order is unchanged, so the actions buttons keep the tags they
        // were built with; only the text needs refreshing.
        for (row, entry) in entries.enumerated() {
            // A header's Hibernate turns off once its project starts
            // hibernating — same sessions, so this path, not a reload.
            if case .group(let group) = entry,
               let cell = tableView.view(atColumn: 0, row: row,
                                         makeIfNecessary: false) as? SessionCellView,
               let button = cell.content as? NSButton {
                styleHibernateButton(button, for: group)
            }
            for (index, column) in Column.allCases.enumerated() where column != .actions {
                guard let cell = tableView.view(atColumn: index, row: row,
                                                makeIfNecessary: false) as? SessionCellView,
                      let label = cell.content as? NSTextField
                else { continue }
                configure(label, with: entry, column: column)
            }
        }
        return true
    }

    /// One place that decides a cell's text, colour and alignment, shared by
    /// creation and in-place update so the two cannot disagree.
    private func configure(_ label: NSTextField, with entry: Entry, column: Column) {
        let value = text(for: entry, column: column)
        if label.stringValue != value { label.stringValue = value }
        let isHeader = entry.session == nil && column == .session
        label.font = ZTheme.chromeFont(size: 12, weight: isHeader ? .semibold : .regular)
        label.textColor = colour(for: entry, column: column, theme: ZTheme.current)
        label.alignment = (column == .cpu || column == .rss) ? .right : .natural
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// The busiest session's CPU, for the status bar's pill.
    var peakCPU: Double? { sessionRows.compactMap(\.load.cpuPercent).max() }

    // MARK: - Actions

    @objc private func modeClicked() { onToggleMode() }

    @objc private func closeClicked() { onClose() }

    @objc private func rowDoubleClicked() {
        guard let row = session(at: tableView.clickedRow), !row.isOrphan else { return }
        onReveal(row)
    }

    @objc private func actionsClicked(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let row = session(at: sender.tag)

        let menu = NSMenu()
        // Enabled state is set by hand: an unavailable Hibernate is shown
        // greyed out with its reason, never silently left out — on Home's
        // rows it read as the action being missing.
        menu.autoenablesItems = false
        // Each item carries the row's KEY, never its index: the sampler keeps
        // ticking while the menu is open, and a re-sort would otherwise aim
        // Interrupt, Kill or Hibernate at whichever row moved into that slot.
        let key = entries[sender.tag].key
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = key
            menu.addItem(item)
            return item
        }

        if let row {
            if !row.isOrphan { _ = add("Reveal Pane", #selector(revealPicked)) }
            _ = add("Interrupt", #selector(interruptPicked))
            menu.addItem(.separator())
        }
        if let group = group(containing: sender.tag), let action = group.action {
            let item = add(Self.actionTitle(action, group: group), #selector(hibernatePicked))
            item.isEnabled = Self.isActionable(action)
            item.toolTip = Self.actionToolTip(action, group: group)
        }
        if let row {
            _ = add(row.isOrphan ? "Kill Session" : "Kill Session…", #selector(killPicked))
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    /// The row a menu item was opened on, re-found by key at pick time.
    private func pickedIndex(_ item: NSMenuItem) -> Int? {
        guard let key = item.representedObject as? String else { return nil }
        return entries.firstIndex { $0.key == key }
    }

    private func pickedSession(_ item: NSMenuItem) -> TaskRow? {
        pickedIndex(item).flatMap(session(at:))
    }

    @objc private func revealPicked(_ sender: NSMenuItem) {
        guard let row = pickedSession(sender) else { return }
        onReveal(row)
    }

    /// Greyed with its reason rather than hidden — a missing control read as
    /// a bug, and so did one greyed with no way to learn why.
    private func styleHibernateButton(_ button: NSButton, for group: TaskGroup) {
        let theme = ZTheme.current
        let actionable = group.action.map(Self.isActionable) ?? false
        button.isEnabled = actionable
        button.contentTintColor = actionable ? theme.fg2Color : theme.fg3Color
        button.toolTip = group.action.map { Self.actionToolTip($0, group: group) }
    }

    private static func isActionable(_ action: TaskGroup.Action) -> Bool {
        if case .unavailable = action { return false }
        return true
    }

    private static func actionTitle(_ action: TaskGroup.Action, group: TaskGroup) -> String {
        "Hibernate “\(group.title)”"
    }

    private static func actionToolTip(_ action: TaskGroup.Action, group: TaskGroup) -> String {
        switch action {
        case .hibernate:
            return "Hibernate “\(group.title)”: free its sessions and processes, keeping its "
                + "layout. Idle shells are asked to exit first."
        case .unavailable(.permanent):
            return "Home and scratch terminals are never hibernated."
        case .unavailable(.endingSessions):
            return "“\(group.title)” is hibernated; its sessions are ending."
        }
    }

    @objc private func hibernateHeaderClicked(_ sender: NSButton) {
        actOnGroup(containing: sender.tag)
    }

    @objc private func hibernatePicked(_ sender: NSMenuItem) {
        guard let index = pickedIndex(sender) else { return }
        actOnGroup(containing: index)
    }

    private func actOnGroup(containing index: Int) {
        guard let group = group(containing: index), let action = group.action,
              Self.isActionable(action), case .project(let id) = group.owner else { return }
        onProjectAction(id)
    }

    /// The group a table row sits under: the nearest header at or above it.
    private func group(containing index: Int) -> TaskGroup? {
        guard entries.indices.contains(index) else { return nil }
        for entry in entries[...index].reversed() {
            if case .group(let group) = entry { return group }
        }
        return nil
    }

    @objc private func interruptPicked(_ sender: NSMenuItem) {
        guard let row = pickedSession(sender) else { return }
        onInterrupt(row)
    }

    @objc private func killPicked(_ sender: NSMenuItem) {
        guard let row = pickedSession(sender) else { return }

        // An orphan needs no confirmation: nothing owns it and nothing is lost.
        guard !row.isOrphan else { onKill(row); return }

        // Named by pane and project, never by session id — that is what the
        // user recognises, and this closes the pane.
        let alert = NSAlert()
        alert.messageText = "Close \(row.paneLabel ?? row.session)?"
        alert.informativeText = """
            This ends the pane and everything running in it. \
            Unsaved work in that shell is lost.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onKill(row)
    }
}

// MARK: - Group rows

/// The row behind a project's header: the table's own surface plus a hairline
/// above every group but the first. The header is an ordinary row — not an
/// `NSTableView` group row, which spans the columns and takes the inset
/// style's section padding — so its name and totals sit in the columns they
/// summarise.
@MainActor
private final class SessionGroupRowView: NSTableRowView {

    private let isFirst: Bool

    init(isFirst: Bool) {
        self.isFirst = isFirst
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    override func drawBackground(in dirtyRect: NSRect) {
        let theme = ZTheme.current
        theme.bg1Color.setFill()
        bounds.fill()
        guard !isFirst else { return }
        theme.borderColor.setFill()
        // Flipped: y = 0 is the top edge.
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

// MARK: - SessionCellView

/// One table cell: its content vertically centred, with a little horizontal
/// breathing room.
///
/// A bare `NSTextField` returned from `viewFor` is sized to the full row
/// height and draws its text at the top of that box, which reads as the rows
/// being misaligned rather than the text.
@MainActor
private final class SessionCellView: NSView {

    let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

// MARK: - Table

extension SessionsView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        session(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        session(at: row) == nil ? 28 : tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        session(at: row) == nil ? SessionGroupRowView(isFirst: row == 0) : nil
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row),
              let raw = tableColumn?.identifier.rawValue,
              let column = Column(rawValue: raw) else { return nil }
        let entry = entries[row]
        let theme = ZTheme.current

        if column == .actions {
            if case .group(let group) = entry {
                // A header's one verb is its project's Hibernate, so it is the
                // button itself rather than a ⋮ with a single item. Orphaned
                // has no project verb, so no button.
                guard group.owner != .orphaned else { return nil }
                let button = NSButton(title: "", target: self,
                                      action: #selector(hibernateHeaderClicked(_:)))
                button.isBordered = false
                button.image = NSImage(systemSymbolName: "moon.zzz",
                                       accessibilityDescription: "Hibernate")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12,
                                                                         weight: .medium))
                button.imagePosition = .imageOnly
                button.tag = row
                styleHibernateButton(button, for: group)
                return SessionCellView(content: button)
            }
            // Vertical (U+22EE): it is the first column, where a horizontal
            // ellipsis reads as truncated text. SF Symbols ships no plain
            // vertical ellipsis on this macOS, so it is a glyph.
            let button = NSButton(title: "⋮", target: self, action: #selector(actionsClicked(_:)))
            button.isBordered = false
            button.font = ZTheme.chromeFont(size: 14, weight: .bold)
            button.contentTintColor = theme.fg2Color
            button.tag = row
            button.toolTip = "Actions for this session"
            return SessionCellView(content: button)
        }

        let label = NSTextField(labelWithString: "")
        configure(label, with: entry, column: column)
        return SessionCellView(content: label)
    }

    private func text(for item: Entry, column: Column) -> String {
        let entry: TaskRow
        switch item {
        case .session(let row): entry = row
        case .group(let group): return text(for: group, column: column)
        }
        switch column {
        case .session: return entry.session
        case .pane: return entry.paneLabel ?? "(no pane)"
        case .running: return entry.running
        case .cpu:
            // "—", never "0.0%": the first tick has nothing to difference
            // against, and zero would be a claim rather than a measurement.
            guard let percent = entry.load.cpuPercent else { return "—" }
            return String(format: "%.1f%%", percent)
        case .rss: return ByteFormat.short(entry.load.rssBytes)
        case .actions: return ""
        }
    }

    /// A header row: the project in SESSION, the count in PANE, and the
    /// group's totals under the columns they sum.
    private func text(for group: TaskGroup, column: Column) -> String {
        switch column {
        case .session: return group.title
        case .pane:
            let count = "\(group.rows.count) session\(group.rows.count == 1 ? "" : "s")"
            return group.isEndingSessions ? count + " · hibernated, ending…" : count
        case .cpu:
            // "—" for an unmeasured group, never "0.0%" — the rows' own rule.
            guard let percent = group.cpuPercent else { return "—" }
            return String(format: "%.1f%%", percent)
        case .rss: return ByteFormat.short(group.rssBytes)
        case .running, .actions: return ""
        }
    }

    private func colour(for item: Entry, column: Column, theme: ZTheme) -> NSColor {
        let entry: TaskRow
        switch item {
        case .session(let row): entry = row
        case .group(let group):
            if column == .session {
                return group.owner == .orphaned ? theme.fg3Color : theme.fgColor
            }
            return theme.fg3Color
        }
        if entry.isOrphan { return theme.fg3Color }
        switch column {
        case .session: return theme.fg3Color
        case .cpu:
            // Attention, not alarm — a busy pane is usually doing its job.
            guard let percent = entry.load.cpuPercent,
                  percent >= SessionsView.busyThreshold else { return theme.fgColor }
            return theme.yellowColor
        default: return theme.fgColor
        }
    }

    /// Above this, a session is "hot" — it tints the CPU cell and is what lets
    /// the status bar's pill break out of the compact menu.
    static let busyThreshold: Double = 80
}
