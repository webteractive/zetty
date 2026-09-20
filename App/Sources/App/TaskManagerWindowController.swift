import AppKit
import ZettyCore

// MARK: - TaskManagerWindowController

/// The Sessions window: every zmx session Zetty spawned, what it is running,
/// what it is costing, and which pane owns it.
///
/// A renderer and nothing more. It never reaches into `TerminalViewController`
/// — rows arrive finished from `taskRows()`, because the workspace and
/// `location(ofSurface:)` are main-only and private. It owns no timer either:
/// `SessionSampler` rides the foreground probe's existing sweep and calls back.
@MainActor
final class TaskManagerWindowController: NSWindowController, NSWindowDelegate {

    private enum Column: String, CaseIterable {
        case session = "SESSION"
        case pane = "PANE"
        case running = "RUNNING"
        case cpu = "CPU"
        // Never "MEM": this is the resident set of the session's own
        // processes, which is a real measurement and explicitly NOT what the
        // pane costs Zetty — per-pane GPU memory is unreachable from Swift.
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

    private let summaryLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var rows: [TaskRow] = []

    init(sampler: SessionSampler,
         rowsProvider: @escaping () -> [TaskRow],
         footprintProvider: @escaping () -> Int64?,
         onReveal: @escaping (TaskRow) -> Void,
         onInterrupt: @escaping (TaskRow) -> Void,
         onKill: @escaping (TaskRow) -> Void) {
        self.sampler = sampler
        self.rowsProvider = rowsProvider
        self.footprintProvider = footprintProvider
        self.onReveal = onReveal
        self.onInterrupt = onInterrupt
        self.onKill = onKill

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sessions"
        window.isReleasedWhenClosed = false
        window.appearance = ZTheme.current.appearance
        window.backgroundColor = ZTheme.current.bg1Color
        window.contentMinSize = NSSize(width: 480, height: 240)
        super.init(window: window)
        window.delegate = self
        buildContents()

        sampler.onUpdate = { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    private func buildContents() {
        guard let content = window?.contentView else { return }
        let theme = ZTheme.current

        summaryLabel.font = ZTheme.chromeFont(size: 12)
        summaryLabel.textColor = theme.fg2Color
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(summaryLabel)

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
            // A column minimum propagates outward as window width the user
            // cannot reclaim; keep it small and let cells truncate.
            item.minWidth = 34
            tableView.addTableColumn(item)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.bg1Color
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        emptyLabel.font = ZTheme.chromeFont(size: 12)
        emptyLabel.textColor = theme.fg3Color
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                                   constant: -16),

            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor,
                                                constant: 16),
        ])
    }

    // MARK: - Lifecycle

    func show() {
        sampler.isActive = true
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Stops the aggregation; the ps sweep itself belongs to the probe and
        // carries on regardless.
        sampler.isActive = false
    }

    // MARK: - Content

    private func reload() {
        // Captured before `rows` is replaced: `selectedRow` is an index into
        // the list currently on screen, and reading it afterwards would look up
        // an old index in a new list.
        //
        // And it is remembered BY SESSION, never by index: the list re-sorts by
        // CPU every few seconds, so restoring the index would quietly move the
        // selection to whichever session took that slot — and the selection is
        // what the actions act on.
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

    // MARK: - Actions

    @objc private func rowDoubleClicked() {
        let index = tableView.clickedRow
        guard rows.indices.contains(index), !rows[index].isOrphan else { return }
        onReveal(rows[index])
    }

    @objc private func actionsClicked(_ sender: NSButton) {
        let index = sender.tag
        guard rows.indices.contains(index) else { return }
        let row = rows[index]

        let menu = NSMenu()
        if !row.isOrphan {
            let reveal = NSMenuItem(title: "Reveal Pane", action: #selector(revealPicked),
                                    keyEquivalent: "")
            reveal.target = self
            reveal.tag = index
            menu.addItem(reveal)
        }
        let interrupt = NSMenuItem(title: "Interrupt", action: #selector(interruptPicked),
                                   keyEquivalent: "")
        interrupt.target = self
        interrupt.tag = index
        menu.addItem(interrupt)
        menu.addItem(.separator())
        let kill = NSMenuItem(title: row.isOrphan ? "Kill Session" : "Kill Session…",
                              action: #selector(killPicked), keyEquivalent: "")
        kill.target = self
        kill.tag = index
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

extension TaskManagerWindowController: NSTableViewDataSource, NSTableViewDelegate {

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
            guard let percent = entry.load.cpuPercent, percent >= 80 else { return theme.fgColor }
            return theme.yellowColor
        default: return theme.fgColor
        }
    }
}
