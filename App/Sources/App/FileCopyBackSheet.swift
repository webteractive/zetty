import AppKit
import ZettyCore

/// Non-git clone → source file copy-back modal. Left: the changed-file list
/// (include checkbox · status · name · Replace/Keep-Both for modified files).
/// Right: the selected file's line diff, colored with ZTheme semantic tokens.
/// Confirming hands the chosen `FileCopyBack.Decision`s to `onApply`.
/// Follows ProjectSettingsSheet's programmatic-AppKit idiom.
@MainActor
final class FileCopyBackSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private static var active: FileCopyBackSheet?

    private final class Row {
        let change: FileCopyBack.FileChange
        var include: Bool = true
        var action: FileCopyBack.Action
        init(_ change: FileCopyBack.FileChange) {
            self.change = change
            self.action = change.kind == .added ? .copyNew : .replace
        }
    }

    private let panel: NSWindow
    private let hostWindow: NSWindow
    private let sourceRoot: String
    private let cloneRoot: String
    private let rows: [Row]
    private let onApply: ([FileCopyBack.Decision]) -> Void

    private let table = NSTableView()
    private let diffView = NSTextView()

    static func present(cloneName: String, sourceRoot: String, cloneRoot: String,
                        changes: [FileCopyBack.FileChange], on window: NSWindow,
                        onApply: @escaping ([FileCopyBack.Decision]) -> Void) {
        let sheet = FileCopyBackSheet(cloneName: cloneName, sourceRoot: sourceRoot,
                                      cloneRoot: cloneRoot, changes: changes,
                                      window: window, onApply: onApply)
        active = sheet
        window.beginSheet(sheet.panel)
    }

    private init(cloneName: String, sourceRoot: String, cloneRoot: String,
                 changes: [FileCopyBack.FileChange], window: NSWindow,
                 onApply: @escaping ([FileCopyBack.Decision]) -> Void) {
        self.hostWindow = window
        self.sourceRoot = sourceRoot
        self.cloneRoot = cloneRoot
        self.rows = changes.map(Row.init)
        self.onApply = onApply

        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                         styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Merge to Source — \(cloneName)"
        panel.appearance = ZTheme.current.appearance
        panel.backgroundColor = ZTheme.current.bg1Color
        super.init()
        buildLayout()
    }

    private func buildLayout() {
        let content = NSView()

        // Left: file table.
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = ZTheme.current.bg1Color
        table.headerView = nil
        table.rowHeight = 22
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        // Right: diff text.
        diffView.isEditable = false
        diffView.drawsBackground = true
        diffView.backgroundColor = ZTheme.current.bg1Color
        diffView.textContainerInset = NSSize(width: 8, height: 8)
        let diffScroll = NSScrollView()
        diffScroll.documentView = diffView
        diffScroll.hasVerticalScroller = true
        diffScroll.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(diffScroll)

        let intro = NSTextField(wrappingLabelWithString:
            "This clone's source isn't a git repository. Choose which changed files to bring "
            + "back. “Replace” overwrites the source's file; “Keep Both” saves the clone's copy "
            + "as “name 2.ext”. Nothing is deleted.")
        intro.font = NSFont.systemFont(ofSize: 12)
        intro.textColor = ZTheme.current.fg2Color
        intro.translatesAutoresizingMaskIntoConstraints = false

        let apply = NSButton(title: "Bring to Source", target: self, action: #selector(applyClicked))
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        [intro, split, buttons].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            split.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            tableScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        panel.contentView = content
        if let first = rows.indices.first {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            renderDiff(for: rows[first])
        } else {
            renderPlain("No differences — the clone matches its source.")
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let model = rows[row]
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6

        let include = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleInclude(_:)))
        include.state = model.include ? .on : .off
        include.tag = row

        let status = NSTextField(labelWithString: model.change.kind == .added ? "A" : "M")
        status.font = ZTheme.monoFont(size: 11)
        status.textColor = model.change.kind == .added ? ZTheme.current.greenColor : ZTheme.current.yellowColor
        status.setContentHuggingPriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: model.change.relPath)
        name.font = ZTheme.monoFont(size: 11)
        name.textColor = ZTheme.current.fgColor
        name.lineBreakMode = .byTruncatingMiddle

        stack.addArrangedSubview(include)
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(name)

        // Modified files get a Replace/Keep-Both selector; added files don't conflict.
        if model.change.kind == .modified {
            let selector = NSSegmentedControl(labels: ["Replace", "Keep Both"],
                                              trackingMode: .selectOne,
                                              target: self, action: #selector(changeAction(_:)))
            selector.selectedSegment = model.action == .keepBoth ? 1 : 0
            selector.tag = row
            selector.segmentDistribution = .fit
            stack.addArrangedSubview(selector)
        }
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0 else { return }
        renderDiff(for: rows[table.selectedRow])
    }

    @objc private func toggleInclude(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].include = sender.state == .on
    }

    @objc private func changeAction(_ sender: NSSegmentedControl) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].action = sender.selectedSegment == 1 ? .keepBoth : .replace
    }

    // MARK: - Diff rendering

    private func renderDiff(for row: Row) {
        let text = FileCopyBackRunner.contentDiff(sourceRoot: sourceRoot, cloneRoot: cloneRoot,
                                                  relPath: row.change.relPath, kind: row.change.kind)
        let result = NSMutableAttributedString()
        let mono = ZTheme.monoFont(size: 11)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let color: NSColor
            if s.hasPrefix("+") { color = ZTheme.current.greenColor }
            else if s.hasPrefix("-") { color = ZTheme.current.redColor }
            else if s.hasPrefix("@@") { color = ZTheme.current.accentColor }
            else if s.hasPrefix("diff ") || s.hasPrefix("index ") { color = ZTheme.current.fg3Color }
            else { color = ZTheme.current.fg2Color }
            result.append(NSAttributedString(string: s + "\n",
                attributes: [.font: mono, .foregroundColor: color]))
        }
        diffView.textStorage?.setAttributedString(result)
    }

    private func renderPlain(_ message: String) {
        diffView.textStorage?.setAttributedString(NSAttributedString(
            string: message,
            attributes: [.font: ZTheme.monoFont(size: 11),
                         .foregroundColor: ZTheme.current.fg2Color]))
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        hostWindow.endSheet(panel)
        Self.active = nil
    }

    @objc private func applyClicked() {
        let decisions = rows.filter(\.include).map {
            FileCopyBack.Decision(change: $0.change, action: $0.action)
        }
        hostWindow.endSheet(panel)
        Self.active = nil
        onApply(decisions)
    }
}
