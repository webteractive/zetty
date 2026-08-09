import AppKit
import ZettyCore

/// A pane's file tree: an `NSOutlineView` over the filesystem below one root,
/// with a fuzzy filename filter.
///
/// Chrome, not terminal — so `ZTheme.chromeFont`, never `monoFont`. Every
/// refresh stays inside this view; nothing here may call `refreshTabBar()` or
/// `refreshSidebar()`.
@MainActor
final class FileTreeView: NSView {

    // MARK: Callbacks

    /// Single click or Enter — peek the file in the read-only viewer.
    var onActivateFile: ((String) -> Void)?
    /// Double click or ⌘Enter — hand the file to the editor.
    var onOpenInEditor: ((String) -> Void)?

    // MARK: State

    private(set) var root: String?
    private let settingsProvider: () -> FileTreeSettings

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let header = NSView()

    private var rootItems: [FileTreeItem] = []
    /// Boxes by path, so `NSOutlineView` identity survives a reload.
    private var itemsByPath: [String: FileTreeItem] = [:]
    private var gitignore = GitignoreStack(matchers: [])
    private var watcher: FileTreeWatcher?

    /// Bumped per root so a slow load landing after a re-root is dropped.
    private var loadGeneration = 0

    // Search
    private var searchIndex: [String] = []
    private var searchIndexTruncated = false
    private var indexGeneration = 0
    private var searchMatches: [FileTreeItem] = []
    private var isFiltering = false
    private var expansionBeforeFiltering: Set<String> = []

    /// `nonisolated` because the background walk reads it off the main actor;
    /// a plain `static let` on a `@MainActor` class is actor-isolated.
    private nonisolated static let indexLimit = 100_000

    init(settingsProvider: @escaping () -> FileTreeSettings) {
        self.settingsProvider = settingsProvider
        super.init(frame: .zero)
        wantsLayer = true
        buildSubviews()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    deinit {
        // `watcher` is only ever touched on the main actor; deinit of a
        // @MainActor class runs there too, so this is safe without a hop.
        watcher?.stop()
    }

    // MARK: Public surface

    /// Directories the user currently has open, for the expansion cache.
    var expandedDirectories: Set<String> {
        var open: Set<String> = []
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? FileTreeItem,
                  outlineView.isItemExpanded(item) else { continue }
            open.insert(item.path)
        }
        return open
    }

    /// Points the tree at `path`, restoring `expanding` where those directories
    /// still exist. A no-op when the root is unchanged.
    func setRoot(_ path: String, expanding: Set<String>) {
        guard path != root else { return }
        root = path
        itemsByPath.removeAll()
        reload(expanding: expanding)
    }

    /// Re-reads the current root from disk, keeping whatever is expanded, and
    /// rebuilds the search index. The escape hatch for anything the watcher
    /// missed.
    func refresh() {
        guard root != nil else { return }
        let open = expandedDirectories
        itemsByPath.removeAll()
        reload(expanding: open)
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Drops cached children so the next expand re-reads. Used by the watcher.
    func invalidateChildren(of path: String) {
        itemsByPath[path]?.children = nil
    }

    // MARK: Loading

    private func reload(expanding: Set<String>) {
        guard let root else {
            rootItems = []
            outlineView.reloadData()
            return
        }
        let settings = settingsProvider()
        loadGeneration += 1
        let generation = loadGeneration

        // Blocking reads, so they happen off-main and the UI is updated back on
        // the main actor.
        DispatchQueue.global(qos: .userInitiated).async {
            let stack = settings.respectGitignore
                ? DirectoryEnumerator.gitignoreStack(root: root)
                : GitignoreStack(matchers: [])
            let children = DirectoryEnumerator.children(of: root)
            let visible = FileTreeFilter.visible(
                children.entries,
                settings: settings,
                isIgnored: { stack.isIgnored(path: $0.path, isDirectory: $0.isDirectory) }
            )
            Task { @MainActor [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.gitignore = stack
                self.rootItems = visible.map { self.item(for: $0) }
                self.outlineView.reloadData()
                self.showEmptyState(isUnreadable: children.isUnreadable,
                                    isEmpty: visible.isEmpty, root: root)
                self.restoreExpansion(expanding)
                self.startWatching(root: root)
                self.buildSearchIndex(root: root, settings: settings, gitignore: stack)
            }
        }
    }

    private func restoreExpansion(_ expanding: Set<String>) {
        guard !expanding.isEmpty else { return }
        // Expanding a row loads its children, which can reveal more rows to
        // expand, so sweep until nothing new opens.
        var didExpand = true
        while didExpand {
            didExpand = false
            for row in 0..<outlineView.numberOfRows {
                guard let item = outlineView.item(atRow: row) as? FileTreeItem,
                      item.isDirectory,
                      expanding.contains(item.path),
                      !outlineView.isItemExpanded(item) else { continue }
                outlineView.expandItem(item)
                didExpand = true
                break                       // row indexes just shifted
            }
        }
    }

    private func item(for entry: FileTreeEntry) -> FileTreeItem {
        // The entry comparison matters: a search result reuses the box for a
        // file already in the tree, but wants the relative path as its name.
        if let existing = itemsByPath[entry.path], existing.entry == entry { return existing }
        let created = FileTreeItem(entry: entry)
        itemsByPath[entry.path] = created
        return created
    }

    /// Loads a directory's children synchronously.
    ///
    /// Synchronous is correct here despite the blocking read: `NSOutlineView`
    /// asks for a child count during an expand and cannot be told "later"
    /// without rendering an empty row that never fills. One directory listing is
    /// fast; the recursive walk behind search is the part that goes off-main.
    private func loadChildren(of item: FileTreeItem) {
        guard item.children == nil else { return }
        let settings = settingsProvider()
        let result = DirectoryEnumerator.children(of: item.path)
        item.isUnreadable = result.isUnreadable
        let stack = gitignore
        item.children = FileTreeFilter.visible(
            result.entries,
            settings: settings,
            isIgnored: { stack.isIgnored(path: $0.path, isDirectory: $0.isDirectory) }
        ).map { self.item(for: $0) }
    }

    // MARK: Watching

    private func startWatching(root: String) {
        watcher?.stop()
        watcher = FileTreeWatcher(root: root) { changed in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for path in changed { self.invalidateChildren(of: path) }
                self.reloadPreservingExpansion()
            }
        }
        syncWatchedDirectories()
    }

    /// Tells the watcher which directories are open right now — everything else
    /// can churn freely without waking the UI.
    private func syncWatchedDirectories() {
        guard let root else { return }
        watcher?.setWatchedDirectories(expandedDirectories.union([root]))
    }

    private func reloadPreservingExpansion() {
        guard !isFiltering else { return }        // a filtered list has no expansion
        let open = expandedDirectories
        outlineView.reloadData()
        restoreExpansion(open)
        syncWatchedDirectories()
    }

    // MARK: Search

    /// One bounded walk per root, feeding the filter field. Runs after the tree
    /// has already painted, so a large project never delays first render.
    private func buildSearchIndex(root: String, settings: FileTreeSettings,
                                  gitignore: GitignoreStack) {
        indexGeneration += 1
        let generation = indexGeneration
        searchIndex = []
        searchIndexTruncated = false
        DispatchQueue.global(qos: .utility).async {
            let result = DirectoryEnumerator.walk(
                root: root, settings: settings, gitignore: gitignore,
                limit: FileTreeView.indexLimit,
                isCancelled: { false }
            )
            Task { @MainActor [weak self] in
                guard let self, generation == self.indexGeneration else { return }
                self.searchIndex = result.paths
                self.searchIndexTruncated = result.truncated
                self.updateStatusLabel()
                if self.isFiltering { self.applyQuery(self.searchField.stringValue) }
            }
        }
    }

    @objc private func queryChanged() {
        applyQuery(searchField.stringValue)
    }

    private func applyQuery(_ query: String) {
        guard let root else { return }
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            guard isFiltering else { return }
            isFiltering = false
            searchMatches = []
            itemsByPath.removeAll()          // search boxes carry relative names
            rootItems = rootItems.map { item(for: $0.entry) }
            outlineView.reloadData()
            restoreExpansion(expansionBeforeFiltering)
            syncWatchedDirectories()
            return
        }

        if !isFiltering {
            // Remember the shape so clearing the field restores it.
            expansionBeforeFiltering = expandedDirectories
            isFiltering = true
        }
        let ranked = FileTreeSearch.rank(query: trimmed, paths: searchIndex, root: root)
        searchMatches = ranked.map { match in
            FileTreeItem(entry: FileTreeEntry(
                name: FileTreeView.displayName(of: match.path, root: root),
                path: match.path,
                isDirectory: false
            ))
        }
        outlineView.reloadData()
    }

    /// Matches show their path relative to the root, so two same-named files in
    /// different directories are distinguishable.
    private static func displayName(of path: String, root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: Empty state

    /// A vanished or unreadable root must say so — an empty tree and a missing
    /// directory look identical otherwise. The next cwd report re-roots and
    /// clears this automatically.
    private func showEmptyState(isUnreadable: Bool, isEmpty: Bool, root: String) {
        let theme = ZTheme.current
        emptyStateLabel.textColor = theme.fg3Color
        if isUnreadable {
            emptyStateLabel.stringValue = "Can't read \((root as NSString).lastPathComponent)"
            emptyStateLabel.isHidden = false
        } else if isEmpty {
            emptyStateLabel.stringValue = "Empty"
            emptyStateLabel.isHidden = false
        } else {
            emptyStateLabel.isHidden = true
        }
    }

    private func updateStatusLabel() {
        statusLabel.textColor = ZTheme.current.yellowColor      // semantic: attention
        statusLabel.stringValue = searchIndexTruncated
            ? "Results limited to first \(FileTreeView.indexLimit) files"
            : ""
        statusLabel.isHidden = !searchIndexTruncated
    }

    // MARK: Building

    private func buildSubviews() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 20
        outlineView.indentationPerLevel = 12
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.doubleAction = #selector(rowDoubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Filter files"
        searchField.font = ZTheme.chromeFont(size: 12)
        searchField.target = self
        searchField.action = #selector(queryChanged)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = ZTheme.chromeFont(size: 10)
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyStateLabel.font = ZTheme.chromeFont(size: 11)
        emptyStateLabel.alignment = .center
        emptyStateLabel.lineBreakMode = .byTruncatingMiddle
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        header.wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(searchField)

        addSubview(header)
        addSubview(scrollView)
        addSubview(statusLabel)
        addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            searchField.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            searchField.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor),

            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            emptyStateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    // MARK: Theming

    /// Re-applies theme tokens.
    ///
    /// **Must** discard cached row rendering: after a scheme change every input
    /// is equal and only the colors differ, so a cache that no-ops here would
    /// freeze the tree in the old palette.
    func applyTheme() {
        let theme = ZTheme.current
        layer?.backgroundColor = theme.bg1Color.cgColor
        outlineView.backgroundColor = theme.bg1Color
        header.layer?.backgroundColor = theme.bg0Color.cgColor
        searchField.textColor = theme.fgColor
        searchField.font = ZTheme.chromeFont(size: 12)
        emptyStateLabel.textColor = theme.fg3Color
        updateStatusLabel()
        outlineView.reloadData()          // forces every cell to restyle
    }

    // MARK: Mouse

    @objc private func rowClicked() {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? FileTreeItem else { return }
        guard !item.isDirectory else { return }     // directories toggle, not peek
        onActivateFile?(item.path)
    }

    @objc private func rowDoubleClicked() {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? FileTreeItem else { return }
        if item.isDirectory {
            toggleExpansion(of: item)
            return
        }
        onOpenInEditor?(item.path)
    }

    private func toggleExpansion(of item: FileTreeItem) {
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
        syncWatchedDirectories()
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter.
        guard event.keyCode == 36 || event.keyCode == 76,
              let item = outlineView.item(atRow: outlineView.selectedRow) as? FileTreeItem else {
            super.keyDown(with: event)
            return
        }
        if item.isDirectory {
            toggleExpansion(of: item)
            return
        }
        if event.modifierFlags.contains(.command) {
            onOpenInEditor?(item.path)
        } else {
            onActivateFile?(item.path)
        }
    }

    // MARK: Context menu

    private func rebuildContextMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileTreeItem else {
            menu.addItem(menuItem("Refresh", #selector(refreshFromMenu), nil))
            return
        }
        menu.addItem(menuItem("Reveal in Finder", #selector(revealInFinder), item))
        menu.addItem(menuItem("Copy Path", #selector(copyPath), item))
        menu.addItem(menuItem("Copy Relative Path", #selector(copyRelativePath), item))
        if !item.isDirectory {
            menu.addItem(.separator())
            menu.addItem(menuItem("Open With Default App", #selector(openWithDefaultApp), item))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Refresh", #selector(refreshFromMenu), nil))
    }

    private func menuItem(_ title: String, _ action: Selector, _ item: FileTreeItem?) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.representedObject = item
        return entry
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileTreeItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileTreeItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    @objc private func copyRelativePath(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileTreeItem, let root else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            FileTreeView.displayName(of: item.path, root: root), forType: .string)
    }

    /// Routes through the same policy ⌘-click uses — `presentFileViewer` applies
    /// `ExternalOpenPolicy`, so a compiled binary is revealed rather than
    /// launched. Never reimplement that hand-off here; the security decision has
    /// exactly one home.
    @objc private func openWithDefaultApp(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileTreeItem else { return }
        onActivateFile?(item.path)
    }

    @objc private func refreshFromMenu(_ sender: NSMenuItem) {
        refresh()
    }
}

// MARK: - NSMenuDelegate

extension FileTreeView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildContextMenu(menu)
    }
}

// MARK: - NSOutlineViewDataSource

extension FileTreeView: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if isFiltering { return item == nil ? searchMatches.count : 0 }
        guard let item = item as? FileTreeItem else { return rootItems.count }
        guard item.isDirectory else { return 0 }
        loadChildren(of: item)
        return item.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if isFiltering { return searchMatches[index] }
        guard let item = item as? FileTreeItem else { return rootItems[index] }
        loadChildren(of: item)
        // `loadChildren` always populates, and `numberOfChildrenOfItem` reports
        // 0 when it can't — so this can't be out of range today. It fails soft
        // anyway: a force-unwrap here would crash the whole multiplexer if a
        // future change ever broke that invariant, which is a steep price for
        // one row.
        guard let children = item.children, children.indices.contains(index) else {
            return FileTreeItem(entry: FileTreeEntry(name: "", path: "", isDirectory: false))
        }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard !isFiltering else { return false }        // a flat result list
        return (item as? FileTreeItem)?.isDirectory ?? false
    }
}

// MARK: - NSOutlineViewDelegate

extension FileTreeView: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let item = item as? FileTreeItem else { return nil }
        let theme = ZTheme.current

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: item.entry.name)
        label.font = ZTheme.chromeFont(size: 12)
        label.textColor = item.isUnreadable ? theme.fg3Color : theme.fgColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: item.isDirectory ? "folder" : "doc",
                             accessibilityDescription: nil)
        icon.contentTintColor = theme.fg3Color
        icon.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        FileTreeRowView()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        syncWatchedDirectories()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        syncWatchedDirectories()
    }
}

/// Selection uses `bg3` — never a saturated accent fill (design rule 3).
@MainActor
private final class FileTreeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        ZTheme.current.bg3Color.setFill()
        bounds.insetBy(dx: 2, dy: 0).fill()
    }
}
