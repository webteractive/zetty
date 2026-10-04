import AppKit
import ZettyCore

// MARK: - SessionsView

/// Every zmx session Zetty spawned: what owns it, what it is running, what it
/// is costing, and the actions to deal with it — grouped under their projects,
/// each header carrying that project's Hibernate.
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
        /// What the agent session in this pane has cost so far, from Zetty's
        /// Claude Code mod. Each pane's own status line shows its own; this is
        /// the one place every session's figure sits side by side.
        case cost = "COST"
        case actions = ""

        var width: CGFloat {
            switch self {
            case .session: return 150
            case .pane: return 210
            case .running: return 110
            case .cpu: return 70
            case .rss: return 100
            case .cost: return 64
            case .actions: return 40
            }
        }
    }

    private let sampler: SessionSampler
    private let groupsProvider: () -> [TaskGroup]
    private let footprintProvider: () -> Int64?
    private let costProvider: (UUID) -> Double?
    private let onReveal: (TaskRow) -> Void
    private let onInterrupt: (TaskRow) -> Void
    private let onKill: (TaskRow) -> Void
    private let onHibernate: (UUID) -> Void
    private let onToggleMode: () -> Void

    private let summaryLabel = NSTextField(labelWithString: "")
    private let modeButton = NSButton()
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
         costProvider: @escaping (UUID) -> Double? = { _ in nil },
         onReveal: @escaping (TaskRow) -> Void,
         onInterrupt: @escaping (TaskRow) -> Void,
         onKill: @escaping (TaskRow) -> Void,
         onHibernate: @escaping (UUID) -> Void,
         onToggleMode: @escaping () -> Void) {
        self.mode = mode
        self.sampler = sampler
        self.groupsProvider = groupsProvider
        self.footprintProvider = footprintProvider
        self.costProvider = costProvider
        self.onReveal = onReveal
        self.onInterrupt = onInterrupt
        self.onKill = onKill
        self.onHibernate = onHibernate
        self.onToggleMode = onToggleMode
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
            if column == .cpu || column == .rss || column == .cost {
                // The cells were right-aligned but the headers were not, which
                // reads as the column itself being misaligned.
                item.headerCell.alignment = .right
            }
            if column == .cost {
                item.headerToolTip = "What this pane's Claude session has cost so far, as "
                    + "Claude Code totals it. On a subscription it is an estimate at list "
                    + "price, not a charge."
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
            modeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            modeButton.widthAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
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
        for (row, item) in entries.enumerated() {
            guard case .session(let entry) = item else {
                if case .group(let group) = item,
                   let header = tableView.view(atColumn: 0, row: row,
                                               makeIfNecessary: false) as? SessionGroupHeaderView {
                    header.update(group)
                }
                continue
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
    private func configure(_ label: NSTextField, with entry: TaskRow, column: Column) {
        let value = text(for: entry, column: column)
        if label.stringValue != value { label.stringValue = value }
        label.font = ZTheme.chromeFont(size: 12)
        label.textColor = colour(for: entry, column: column, theme: ZTheme.current)
        label.alignment = (column == .cpu || column == .rss || column == .cost) ? .right : .natural
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// The busiest session's CPU, for the status bar's pill.
    var peakCPU: Double? { sessionRows.compactMap(\.load.cpuPercent).max() }

    // MARK: - Actions

    @objc private func modeClicked() { onToggleMode() }

    @objc private func rowDoubleClicked() {
        guard let row = session(at: tableView.clickedRow), !row.isOrphan else { return }
        onReveal(row)
    }

    @objc private func actionsClicked(_ sender: NSButton) {
        guard let row = session(at: sender.tag) else { return }

        let menu = NSMenu()
        if !row.isOrphan {
            let reveal = NSMenuItem(title: "Reveal Pane", action: #selector(revealPicked),
                                    keyEquivalent: "")
            reveal.target = self
            reveal.tag = sender.tag
            menu.addItem(reveal)
        }
        let interrupt = NSMenuItem(title: "Interrupt", action: #selector(interruptPicked),
                                   keyEquivalent: "")
        interrupt.target = self
        interrupt.tag = sender.tag
        menu.addItem(interrupt)
        menu.addItem(.separator())
        let kill = NSMenuItem(title: row.isOrphan ? "Kill Session" : "Kill Session…",
                              action: #selector(killPicked), keyEquivalent: "")
        kill.target = self
        kill.tag = sender.tag
        menu.addItem(kill)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func revealPicked(_ sender: NSMenuItem) {
        guard let row = session(at: sender.tag) else { return }
        onReveal(row)
    }

    @objc private func interruptPicked(_ sender: NSMenuItem) {
        guard let row = session(at: sender.tag) else { return }
        onInterrupt(row)
    }

    @objc private func killPicked(_ sender: NSMenuItem) {
        guard let row = session(at: sender.tag) else { return }

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

/// A project's header row: its name, what its sessions cost together, and its
/// Hibernate. Styled like the sidebar's section headers, separated by a
/// hairline rather than a fill (depth is borders + surfaces).
@MainActor
private final class SessionGroupHeaderView: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let hibernateButton = NSButton()
    private let onHibernate: (UUID) -> Void
    private var projectID: UUID?

    init(onHibernate: @escaping (UUID) -> Void) {
        self.onHibernate = onHibernate
        super.init(frame: .zero)

        titleLabel.font = ZTheme.chromeFont(size: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = ZTheme.chromeFont(size: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        hibernateButton.isBordered = false
        hibernateButton.title = "Hibernate"
        hibernateButton.font = ZTheme.chromeFont(size: 11)
        hibernateButton.image = NSImage(systemSymbolName: "moon.zzz",
                                        accessibilityDescription: "Hibernate")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        hibernateButton.imagePosition = .imageLeading
        hibernateButton.target = self
        hibernateButton.action = #selector(hibernateClicked)
        hibernateButton.toolTip = "Free this project's sessions and processes, keeping its layout. "
            + "Idle shells are asked to exit first."

        for view in [titleLabel, detailLabel, hibernateButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: hibernateButton.leadingAnchor,
                                                  constant: -8),
            hibernateButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hibernateButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(_ group: TaskGroup) {
        let theme = ZTheme.current
        if case .project(let id) = group.owner { projectID = id } else { projectID = nil }

        titleLabel.textColor = group.owner == .orphaned ? theme.fg3Color : theme.fgColor
        if titleLabel.stringValue != group.title { titleLabel.stringValue = group.title }

        var detail = "\(group.rows.count) session\(group.rows.count == 1 ? "" : "s")"
        // "—" for an unmeasured group, never "0.0%" — the rows' own rule.
        detail += " · " + (group.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
        detail += " · " + ByteFormat.short(group.rssBytes)
        if group.isHibernating { detail += " · hibernating…" }
        if detailLabel.stringValue != detail { detailLabel.stringValue = detail }
        detailLabel.textColor = theme.fg3Color

        hibernateButton.isHidden = !group.canHibernate
        hibernateButton.contentTintColor = theme.fg2Color
        hibernateButton.attributedTitle = NSAttributedString(
            string: "Hibernate",
            attributes: [.font: ZTheme.chromeFont(size: 11), .foregroundColor: theme.fg2Color])
    }

    @objc private func hibernateClicked() {
        guard let projectID else { return }
        onHibernate(projectID)
    }
}

/// The row behind a group header: the table's own surface plus a hairline
/// above every group but the first, instead of the system group-row fill.
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

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        entries.indices.contains(row) && entries[row].session == nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        session(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        session(at: row) == nil ? 30 : tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        // The system group-row style paints its own (non-theme) background.
        session(at: row) == nil ? SessionGroupRowView(isFirst: row == 0) : nil
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        if case .group(let group) = entries[row] {
            let header = SessionGroupHeaderView(onHibernate: { [weak self] id in
                self?.onHibernate(id)
            })
            header.update(group)
            return header
        }
        guard let entry = session(at: row),
              let raw = tableColumn?.identifier.rawValue,
              let column = Column(rawValue: raw) else { return nil }
        let theme = ZTheme.current

        if column == .actions {
            let button = NSButton(title: "⋯", target: self, action: #selector(actionsClicked(_:)))
            button.isBordered = false
            button.font = ZTheme.chromeFont(size: 13, weight: .bold)
            button.contentTintColor = theme.fg2Color
            button.tag = row
            button.toolTip = "Actions for this session"
            return SessionCellView(content: button)
        }

        let label = NSTextField(labelWithString: "")
        configure(label, with: entry, column: column)
        return SessionCellView(content: label)
    }

    private func text(for entry: TaskRow, column: Column) -> String {
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
        case .cost:
            // Empty, never "$0.00": most rows are not Claude sessions at all.
            guard let cost = entry.surfaceID.flatMap(costProvider) else { return "" }
            return String(format: "$%.2f", cost)
        case .actions: return ""
        }
    }

    private func colour(for entry: TaskRow, column: Column, theme: ZTheme) -> NSColor {
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
