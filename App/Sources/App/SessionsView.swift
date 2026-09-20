import AppKit
import ZettyCore

// MARK: - SessionsView

/// Every zmx session Zetty spawned: what owns it, what it is running, what it
/// is costing, and the actions to deal with it.
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
        // Never "MEM": this is the resident set of the session's own
        // processes, a real measurement, and explicitly NOT what the pane
        // costs Zetty — per-pane GPU memory is unreachable from Swift.
        case rss = "SESSION RSS"
        case actions = ""

        var width: CGFloat {
            switch self {
            case .session: return 150
            case .pane: return 210
            case .running: return 110
            case .cpu: return 70
            case .rss: return 100
            case .actions: return 40
            }
        }
    }

    private let sampler: SessionSampler
    private let rowsProvider: () -> [TaskRow]
    private let footprintProvider: () -> Int64?
    private let onReveal: (TaskRow) -> Void
    private let onInterrupt: (TaskRow) -> Void
    private let onKill: (TaskRow) -> Void
    private let onToggleMode: () -> Void

    private let summaryLabel = NSTextField(labelWithString: "")
    private let modeButton = NSButton()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let topBorder = NSView()
    private var rows: [TaskRow] = []

    /// Which host this instance is in, deciding only the mode button's glyph.
    private let mode: SessionsViewMode

    init(mode: SessionsViewMode,
         sampler: SessionSampler,
         rowsProvider: @escaping () -> [TaskRow],
         footprintProvider: @escaping () -> Int64?,
         onReveal: @escaping (TaskRow) -> Void,
         onInterrupt: @escaping (TaskRow) -> Void,
         onKill: @escaping (TaskRow) -> Void,
         onToggleMode: @escaping () -> Void) {
        self.mode = mode
        self.sampler = sampler
        self.rowsProvider = rowsProvider
        self.footprintProvider = footprintProvider
        self.onReveal = onReveal
        self.onInterrupt = onInterrupt
        self.onKill = onKill
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
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        for column in Column.allCases {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            item.title = column.rawValue
            item.width = column.width
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
        let symbol = docked ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)) {
            modeButton.image = image
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
        // Captured before `rows` is replaced: `selectedRow` indexes the list
        // currently on screen.
        //
        // Remembered BY SESSION, never by index: the list re-sorts by CPU every
        // few seconds, so restoring an index would quietly move the selection
        // to whichever session took that slot — and the selection is what the
        // row actions act on.
        let previouslySelected = rows.indices.contains(tableView.selectedRow)
            ? rows[tableView.selectedRow].session
            : nil

        rows = rowsProvider()
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

        tableView.reloadData()
        if let previouslySelected,
           let restored = rows.firstIndex(where: { $0.session == previouslySelected }) {
            tableView.selectRowIndexes(IndexSet(integer: restored), byExtendingSelection: false)
        }
    }

    /// The busiest session's CPU, for the status bar's pill.
    var peakCPU: Double? { rows.compactMap(\.load.cpuPercent).max() }

    // MARK: - Actions

    @objc private func modeClicked() { onToggleMode() }

    @objc private func rowDoubleClicked() {
        let index = tableView.clickedRow
        guard rows.indices.contains(index), !rows[index].isOrphan else { return }
        onReveal(rows[index])
    }

    @objc private func actionsClicked(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag]

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
        guard rows.indices.contains(sender.tag) else { return }
        onReveal(rows[sender.tag])
    }

    @objc private func interruptPicked(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag) else { return }
        onInterrupt(rows[sender.tag])
    }

    @objc private func killPicked(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag]

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

// MARK: - Table

extension SessionsView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row),
              let raw = tableColumn?.identifier.rawValue,
              let column = Column(rawValue: raw) else { return nil }
        let entry = rows[row]
        let theme = ZTheme.current

        if column == .actions {
            let button = NSButton(title: "⋯", target: self, action: #selector(actionsClicked(_:)))
            button.isBordered = false
            button.font = ZTheme.chromeFont(size: 13, weight: .bold)
            button.contentTintColor = theme.fg2Color
            button.tag = row
            button.toolTip = "Actions for this session"
            return button
        }

        let label = NSTextField(labelWithString: text(for: entry, column: column))
        label.font = ZTheme.chromeFont(size: 12)
        label.textColor = colour(for: entry, column: column, theme: theme)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if column == .cpu || column == .rss { label.alignment = .right }
        return label
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
