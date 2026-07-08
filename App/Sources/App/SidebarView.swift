import AppKit
import ZettyCore

// MARK: - SidebarProject

/// Plain data for one project row in the sidebar.
///
/// When `tabTitles.count >= 2` the project row is expandable and its children
/// are the individual tab titles.  A single-tab project is a plain leaf row.
struct SidebarProject {
    let name: String
    let isPinned: Bool
    let tabTitles: [String]              // .count >= 2 → expandable
    let tabStatuses: [AgentStatus?]      // parallel to tabTitles (agent status per tab)
    let tabIcons: [NSImage?]             // parallel to tabTitles (tool logo per tab)
    let icon: NSImage?                   // single-tab projects: the pane's tool logo
    let status: AgentStatus?             // project roll-up (most-severe across tabs)
    let projectColor: NSColor?           // per-project identity color (nil = default)
    let customGlyph: String?             // SF Symbol overriding the diamond (nil = default)
    let isHibernated: Bool               // frozen: dimmed row + moon glyph
    let isScratch: Bool                  // project-less ephemeral terminal (Scratch section)
}

/// Maps an agent status to its status-dot color, or nil for "no agent".
func agentStatusColor(_ status: AgentStatus?) -> NSColor? {
    switch status {
    case .running:        return ZTheme.current.greenColor
    case .needsAttention: return ZTheme.current.yellowColor
    case .idle:           return ZTheme.current.fg3Color
    case nil:             return nil
    }
}

// MARK: - Outline item model

/// A top-level section grouping.
private enum SidebarSection: Hashable {
    case pinned
    case projects
    case scratch
    case hibernated

    var title: String {
        switch self {
        case .pinned:     return "Pinned"
        case .projects:   return "Projects"
        case .scratch:    return "Scratch"
        case .hibernated: return "Hibernating"
        }
    }
}

/// Identity-stable wrapper used as NSOutlineView item objects.
///
/// NSOutlineView requires object identity for items, so we box a simple enum
/// in a class.  Two `OutlineItem` instances are equal iff they wrap the same
/// case with the same values.  `project`/`tab` indices are into the full
/// (unfiltered) projects array, so callbacks report real indices.
private final class OutlineItem: NSObject {
    enum Kind: Hashable {
        case header(SidebarSection)
        case project(Int)
        case tab(project: Int, tab: Int)
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? OutlineItem else { return false }
        return kind == other.kind
    }
    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(kind)
        return hasher.finalize()
    }
}

// MARK: - SidebarView

/// A sectioned sidebar backed by an `NSOutlineView`.
///
/// Top level is a filterable list of section headers (`Pinned` / `Projects`,
/// with counts) and project rows; a project expands to its tab children when it
/// has 2+ tabs.  The view is dumb — it takes plain display data in and reports
/// user actions out via closures.  No ZettyCore import.
@MainActor
final class SidebarView: NSView {

    // MARK: - Callbacks

    /// Called with the project index when the user clicks a project row.
    var onSelectProject: ((Int) -> Void)?

    /// Called with (projectIndex, tabIndex) when the user clicks a tab child row.
    var onSelectTab: ((Int, Int) -> Void)?

    /// Called when a tab child row is drag-reordered within its project:
    /// (projectIndex, fromTab, toTab).
    var onMoveTab: ((Int, Int, Int) -> Void)?

    /// Called when a project row is drag-reordered within its section (Pinned or
    /// Projects): (fromProjectIndex, toProjectIndex), both real `projects` indices.
    var onMoveProject: ((Int, Int) -> Void)?

    /// Called when the user clicks the "+" Add Project button (opens the picker).
    var onAddProject: (() -> Void)?

    /// Called with the project index when the user clicks the pin button.
    var onTogglePin: ((Int) -> Void)?

    /// Called with the project index when the user picks "Remove Project…"
    /// from a project row's context menu.
    var onRemoveProject: ((Int) -> Void)?

    /// Called with the project index for the context menu's "Rename…".
    var onRenameProject: ((Int) -> Void)?
    var onToggleHibernate: ((Int) -> Void)?

    /// Called with the project index for the context menu's "Project Settings…".
    var onOpenProjectSettings: ((Int) -> Void)?

    // MARK: - Private state

    /// The full (unfiltered) project list as last received, pinned-first sorted.
    private var projects: [SidebarProject] = []
    private var activeProject: Int = -1
    private var activeTab: Int = -1

    /// Current filter text (case-insensitive substring on project name).
    private var filterText: String = ""

    /// True while a tab or project row is being drag-reordered — freezes
    /// `update(...)` reloads, which would cancel the outline view's drag session.
    private var isReordering = false

    /// The top-level rows currently displayed (headers + visible projects).
    private var topLevel: [OutlineItem.Kind] = []
    private var pinnedCount = 0
    private var projectsCount = 0
    private var scratchCount = 0
    private var hibernatedCount = 0

    // Item-object cache — keyed by Kind so we reuse the same object across
    // reloads (NSOutlineView uses pointer/isEqual identity for expansion state).
    private var itemCache: [OutlineItem.Kind: OutlineItem] = [:]

    // MARK: - Subviews

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    /// Pill surface behind the Add-project button (matches the status bar's
    /// Open pill: bg2 + border, fully rounded).
    private let addPill = NSView()

    /// Attention bell (bottom-right, beside Add project): dim when clear,
    /// filled yellow with a count while any agent needs attention.
    private let bellButton = NSButton()
    private var attentionCount = 0

    /// Settings gear (bottom-right corner).
    private let gearButton = NSButton()

    /// Compact add-project button beside the search field.
    private let topAddButton = NSButton()

    /// Shows the attention list (panes whose agents need attention).
    var onShowBellMenu: ((NSView) -> Void)?

    /// Opens the Settings window (⌘, equivalent).
    var onOpenSettings: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = ZTheme.current.bg0Color.cgColor

        setupSearchField()
        setupOutlineView()
        setupAddButton()
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // MARK: - Setup

    private func setupSearchField() {
        searchField.placeholderString = "Filter projects…"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        styleSearchField()
        addSubview(searchField)
    }

    private func styleSearchField() {
        searchField.font = ZTheme.chromeFont(size: 12)
        searchField.textColor = ZTheme.current.fgColor
        // The control renders its bezel/icons per its own appearance — pin it
        // to the scheme's axis or it lags behind dark↔light switches.
        searchField.appearance = ZTheme.current.appearance
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.backgroundColor = ZTheme.current.bg2Color
            cell.drawsBackground = true
            cell.placeholderAttributedString = NSAttributedString(
                string: "Filter projects…",
                attributes: [
                    .font: ZTheme.chromeFont(size: 12),
                    .foregroundColor: ZTheme.current.fg3Color,
                ]
            )
        }
        // Cell color changes don't invalidate the field on their own.
        searchField.needsDisplay = true
    }

    private func setupOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemColumn"))
        column.minWidth = 160
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 28
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.indentationPerLevel = 14
        outlineView.indentationMarkerFollowsCell = true
        outlineView.backgroundColor = ZTheme.current.bg0Color
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        // Tab child rows can be drag-reordered within their project.
        outlineView.registerForDraggedTypes([SidebarView.tabDragType, SidebarView.projectDragType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        // Context menu — populated per-row in `menuNeedsUpdate`.
        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ZTheme.current.bg0Color
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
    }

    private func setupAddButton() {
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.imagePosition = .imageLeading
        addButton.alignment = .left
        addButton.target = self
        addButton.action = #selector(addButtonClicked(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        styleAddButton()
        addPill.wantsLayer = true
        addPill.layer?.cornerRadius = 12
        addPill.layer?.borderWidth = 1
        addPill.translatesAutoresizingMaskIntoConstraints = false
        addPill.addSubview(addButton)
        addSubview(addPill)
        NSLayoutConstraint.activate([
            addButton.leadingAnchor.constraint(equalTo: addPill.leadingAnchor, constant: 10),
            addButton.trailingAnchor.constraint(equalTo: addPill.trailingAnchor, constant: -11),
            addButton.centerYAnchor.constraint(equalTo: addPill.centerYAnchor),
        ])

        bellButton.bezelStyle = .inline
        bellButton.isBordered = false
        bellButton.imagePosition = .imageLeading
        bellButton.imageHugsTitle = true
        bellButton.target = self
        bellButton.action = #selector(bellClicked(_:))
        bellButton.translatesAutoresizingMaskIntoConstraints = false
        styleBellButton()
        addSubview(bellButton)

        gearButton.bezelStyle = .inline
        gearButton.isBordered = false
        gearButton.imagePosition = .imageOnly
        gearButton.target = self
        gearButton.action = #selector(gearClicked(_:))
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        gearButton.toolTip = "Settings (⌘,)"
        styleGearButton()
        addSubview(gearButton)

        topAddButton.bezelStyle = .inline
        topAddButton.isBordered = false
        topAddButton.imagePosition = .imageOnly
        topAddButton.target = self
        topAddButton.action = #selector(addButtonClicked(_:))
        topAddButton.translatesAutoresizingMaskIntoConstraints = false
        topAddButton.toolTip = "Add or create a project"
        styleTopAddButton()
        addSubview(topAddButton)
    }

    private func styleAddButton() {
        if let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add project")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)) {
            addButton.image = plus
            addButton.contentTintColor = ZTheme.current.fg2Color
        }
        addButton.attributedTitle = NSAttributedString(
            string: " Add project",
            attributes: [
                .font: ZTheme.chromeFont(size: 12, weight: .medium),
                .foregroundColor: ZTheme.current.fgColor,
            ]
        )
        addPill.layer?.backgroundColor = ZTheme.current.bg2Color.cgColor
        addPill.layer?.borderColor = ZTheme.current.borderColor.cgColor
    }

    @objc private func bellClicked(_: Any?) {
        onShowBellMenu?(bellButton)
    }

    @objc private func gearClicked(_: Any?) {
        onOpenSettings?()
    }

    private func styleGearButton() {
        if #available(macOS 11.0, *) {
            gearButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        } else {
            gearButton.title = "⚙"
        }
        gearButton.contentTintColor = ZTheme.current.fg3Color
    }

    private func styleTopAddButton() {
        if #available(macOS 11.0, *) {
            topAddButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add project")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        } else {
            topAddButton.title = "+"
        }
        topAddButton.contentTintColor = ZTheme.current.fg2Color
    }

    /// Updates the attention bell state (count of panes needing attention).
    func updateBell(count: Int) {
        attentionCount = count
        styleBellButton()
    }

    private func styleBellButton() {
        let theme = ZTheme.current
        let attention = attentionCount > 0
        if #available(macOS 11.0, *) {
            bellButton.image = NSImage(
                systemSymbolName: attention ? "bell.fill" : "bell",
                accessibilityDescription: "Agent attention"
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        }
        bellButton.contentTintColor = attention ? theme.yellowColor : theme.fg3Color
        bellButton.attributedTitle = NSAttributedString(
            string: attention ? " \(attentionCount)" : "",
            attributes: [
                .font: ZTheme.chromeFont(size: 12.5, weight: .semibold),
                .foregroundColor: theme.yellowColor,
            ]
        )
        bellButton.toolTip = attention
            ? "\(attentionCount) pane\(attentionCount == 1 ? "" : "s") need attention — click to jump"
            : "No agent needs attention"
    }

    private func setupLayout() {
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: topAddButton.leadingAnchor, constant: -6),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            topAddButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            topAddButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            topAddButton.widthAnchor.constraint(equalToConstant: 22),
            topAddButton.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addPill.topAnchor, constant: -6),

            addPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            addPill.trailingAnchor.constraint(lessThanOrEqualTo: bellButton.leadingAnchor, constant: -8),
            addPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            addPill.heightAnchor.constraint(equalToConstant: 24),

            gearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            gearButton.centerYAnchor.constraint(equalTo: addPill.centerYAnchor),
            gearButton.heightAnchor.constraint(equalToConstant: 24),

            bellButton.trailingAnchor.constraint(equalTo: gearButton.leadingAnchor, constant: -10),
            bellButton.centerYAnchor.constraint(equalTo: addPill.centerYAnchor),
            bellButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Theme

    func applyTheme() {
        layer?.backgroundColor = ZTheme.current.bg0Color.cgColor
        outlineView.backgroundColor = ZTheme.current.bg0Color
        scrollView.backgroundColor = ZTheme.current.bg0Color
        styleSearchField()
        styleAddButton()
        styleBellButton()
        styleGearButton()
        styleTopAddButton()
    }

    // MARK: - Item-object helpers

    private func item(for kind: OutlineItem.Kind) -> OutlineItem {
        if let existing = itemCache[kind] { return existing }
        let obj = OutlineItem(kind)
        itemCache[kind] = obj
        return obj
    }

    // MARK: - Update

    /// True while `update()`/rebuild is programmatically adjusting the outline
    /// view, so `outlineViewSelectionDidChange` doesn't re-fire callbacks.
    private var isUpdating = false

    /// Replaces the displayed data, then rebuilds the sectioned outline.
    func update(projects: [SidebarProject], activeProject: Int, activeTab: Int) {
        // Reloading mid-drag cancels the outline view's drag session (live
        // agents retitle rows every second) — freeze until the drop lands.
        guard !isReordering else { return }
        self.projects = projects
        self.activeProject = activeProject
        self.activeTab = activeTab
        rebuildOutline()
    }

    /// Applies the current filter, rebuilds the section/project rows, reloads,
    /// and restores expansion + selection for the active project.
    private func rebuildOutline() {
        isUpdating = true
        defer { isUpdating = false }

        // Filter (case-insensitive substring) while keeping real indices.
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = projects.enumerated().filter { _, p in
            query.isEmpty || p.name.lowercased().contains(query)
        }
        // Sections: Pinned · Projects · Scratch · Hibernating. Scratch terminals
        // (project-less, ephemeral) get their own group; hibernated projects sit
        // at the bottom regardless of pin state.
        let awake = visible.filter { !$0.element.isHibernated }
        let hibernated = visible.filter { $0.element.isHibernated }
        let scratch = awake.filter { $0.element.isScratch }
        let regular = awake.filter { !$0.element.isScratch }
        let pinned = regular.filter { $0.element.isPinned }
        let unpinned = regular.filter { !$0.element.isPinned }
        pinnedCount = pinned.count
        projectsCount = unpinned.count
        scratchCount = scratch.count
        hibernatedCount = hibernated.count

        var rows: [OutlineItem.Kind] = []
        if !pinned.isEmpty {
            rows.append(.header(.pinned))
            rows += pinned.map { .project($0.offset) }
        }
        if !unpinned.isEmpty {
            rows.append(.header(.projects))
            rows += unpinned.map { .project($0.offset) }
        }
        if !scratch.isEmpty {
            rows.append(.header(.scratch))
            rows += scratch.map { .project($0.offset) }
        }
        if !hibernated.isEmpty {
            rows.append(.header(.hibernated))
            rows += hibernated.map { .project($0.offset) }
        }
        topLevel = rows

        // Evict stale cache entries.
        itemCache = itemCache.filter { kind, _ in
            switch kind {
            case .header:               return true
            case .project(let p):       return projects.indices.contains(p)
            case .tab(let p, let t):
                return projects.indices.contains(p) && projects[p].tabTitles.indices.contains(t)
            }
        }

        outlineView.reloadData()

        // Auto-expand the active project if it is visible + expandable (never a
        // hibernated project — those are dormant leaf rows).
        let activeExpandable = activeProject >= 0
            && projects.indices.contains(activeProject)
            && !projects[activeProject].isHibernated
            && projects[activeProject].tabTitles.count >= 2
        let activeVisible = topLevel.contains(.project(activeProject))
        if activeVisible, activeExpandable {
            outlineView.expandItem(item(for: .project(activeProject)))
        }

        // Select the active tab child (or the project row), if visible.
        let rowToSelect: Int
        if activeVisible, activeExpandable {
            rowToSelect = outlineView.row(forItem: item(for: .tab(project: activeProject, tab: activeTab)))
        } else if activeVisible {
            rowToSelect = outlineView.row(forItem: item(for: .project(activeProject)))
        } else {
            rowToSelect = -1
        }

        if rowToSelect >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: rowToSelect), byExtendingSelection: false)
            outlineView.scrollRowToVisible(rowToSelect)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    // MARK: - Actions

    @objc private func addButtonClicked(_: Any?) {
        // Opens the unified Add Project picker directly (no menu).
        onAddProject?()
    }

    @objc private func pinButtonClicked(_ sender: NSButton) {
        let projectIndex = sender.tag
        guard projects.indices.contains(projectIndex) else { return }
        onTogglePin?(projectIndex)
    }

    @objc private func removeProjectMenuClicked(_ sender: NSMenuItem) {
        let projectIndex = sender.tag
        guard projects.indices.contains(projectIndex) else { return }
        onRemoveProject?(projectIndex)
    }

    @objc private func hibernateMenuClicked(_ sender: NSMenuItem) {
        let projectIndex = sender.tag
        guard projects.indices.contains(projectIndex) else { return }
        onToggleHibernate?(projectIndex)
    }

    @objc private func renameProjectMenuClicked(_ sender: NSMenuItem) {
        let projectIndex = sender.tag
        guard projects.indices.contains(projectIndex) else { return }
        onRenameProject?(projectIndex)
    }

    @objc private func projectSettingsMenuClicked(_ sender: NSMenuItem) {
        let projectIndex = sender.tag
        guard projects.indices.contains(projectIndex) else { return }
        onOpenProjectSettings?(projectIndex)
    }
}

// MARK: - NSMenuDelegate (project row context menu)

extension SidebarView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0,
              let obj = outlineView.item(atRow: row) as? OutlineItem,
              case .project(let p) = obj.kind,
              projects.indices.contains(p) else { return }

        let isScratch = projects[p].isScratch

        let rename = NSMenuItem(title: "Rename\u{2026}",
                                action: #selector(renameProjectMenuClicked(_:)),
                                keyEquivalent: "")
        rename.target = self
        rename.tag = p
        menu.addItem(rename)

        // Scratch terminals are project-less and ephemeral: no per-project
        // settings and no hibernation.
        if !isScratch {
            let settings = NSMenuItem(title: "Project Settings\u{2026}",
                                      action: #selector(projectSettingsMenuClicked(_:)),
                                      keyEquivalent: "")
            settings.target = self
            settings.tag = p
            menu.addItem(settings)

            let hibernate = NSMenuItem(
                title: projects[p].isHibernated ? "Wake Project" : "Hibernate Project",
                action: #selector(hibernateMenuClicked(_:)), keyEquivalent: "")
            hibernate.target = self
            hibernate.tag = p
            menu.addItem(hibernate)
        }

        menu.addItem(.separator())

        let remove = NSMenuItem(title: isScratch ? "Close Terminal" : "Remove Project\u{2026}",
                                action: #selector(removeProjectMenuClicked(_:)),
                                keyEquivalent: "")
        remove.target = self
        remove.tag = p
        remove.isEnabled = projects.count > 1   // the last project can't be removed
        menu.addItem(remove)
    }
}

// MARK: - NSSearchFieldDelegate

extension SidebarView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        filterText = searchField.stringValue
        rebuildOutline()
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarView: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return topLevel.count }
        guard let obj = item as? OutlineItem,
              case .project(let p) = obj.kind,
              projects.indices.contains(p) else { return 0 }
        // Hibernated projects are dormant leaf rows — no tab children.
        if projects[p].isHibernated { return 0 }
        let count = projects[p].tabTitles.count
        return count >= 2 ? count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return self.item(for: topLevel[index])
        }
        guard let obj = item as? OutlineItem,
              case .project(let p) = obj.kind else {
            return self.item(for: topLevel[0])   // fallback (should never happen)
        }
        return self.item(for: .tab(project: p, tab: index))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let obj = item as? OutlineItem,
              case .project(let p) = obj.kind,
              projects.indices.contains(p) else { return false }
        return !projects[p].isHibernated && projects[p].tabTitles.count >= 2
    }

    // MARK: Drag-reorder (tab children within a project · project rows within a section)

    static let tabDragType = NSPasteboard.PasteboardType("co.webteractive.zetty.sidebar-tab")
    static let projectDragType = NSPasteboard.PasteboardType("co.webteractive.zetty.sidebar-project")

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let obj = item as? OutlineItem else { return nil }
        switch obj.kind {
        case .tab(let project, let tab):
            let pb = NSPasteboardItem()
            pb.setString("\(project):\(tab)", forType: SidebarView.tabDragType)
            return pb
        case .project(let p):
            // No project drag while filtering (visible rows are a subset, so
            // offsets don't map to neighbours) or for hibernated rows (that
            // section isn't reorderable).
            guard filterText.trimmingCharacters(in: .whitespaces).isEmpty,
                  projects.indices.contains(p), !projects[p].isHibernated else { return nil }
            let pb = NSPasteboardItem()
            pb.setString("\(p)", forType: SidebarView.projectDragType)
            return pb
        case .header:
            return nil
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
    ) {
        isReordering = true
    }

    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        isReordering = false
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Tab child: only between the SAME project's tab children (never onto a row).
        if let source = draggedTab(from: info) {
            guard index >= 0,
                  let obj = item as? OutlineItem,
                  case .project(let targetProject) = obj.kind,
                  targetProject == source.project else { return [] }
            return .move
        }

        // Project row: only top-level gaps, snapped to stay inside its section.
        guard let from = draggedProject(from: info),
              projects.indices.contains(from),
              let range = projectRowRange(for: section(forProjectAt: from))
        else { return [] }
        let clamped = clampProjectDrop(index, into: range)
        if item != nil || index != clamped {
            outlineView.setDropItem(nil, dropChildIndex: clamped)
        }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
        item: Any?, childIndex index: Int
    ) -> Bool {
        // Tab child move within a project.
        if let source = draggedTab(from: info) {
            guard index >= 0,
                  let obj = item as? OutlineItem,
                  case .project(let targetProject) = obj.kind,
                  targetProject == source.project else { return false }
            // The gap index counts the row's own old slot when moving down.
            let destination = index > source.tab ? index - 1 : index
            guard destination != source.tab else { return false }
            isReordering = false
            onMoveTab?(source.project, source.tab, destination)
            return true
        }

        // Project row move within a section.
        guard let from = draggedProject(from: info),
              projects.indices.contains(from),
              let range = projectRowRange(for: section(forProjectAt: from)) else { return false }
        let sectionOffsets = topLevel[range].compactMap { kind -> Int? in
            if case .project(let o) = kind { return o } else { return nil }
        }
        guard let base = sectionOffsets.first else { return false }
        let clamped = clampProjectDrop(index, into: range)
        // Section rows are contiguous in model order, so a topLevel gap maps to a
        // model gap by offsetting from the section's first project.
        let modelGap = base + (clamped - range.lowerBound)
        // The gap counts the row's own old slot when moving down.
        let to = modelGap > from ? modelGap - 1 : modelGap
        guard to != from else { return false }
        isReordering = false
        onMoveProject?(from, to)
        return true
    }

    /// Decodes the dragged tab's "project:tab" pasteboard payload.
    private func draggedTab(from info: NSDraggingInfo) -> (project: Int, tab: Int)? {
        guard let payload = info.draggingPasteboard.string(forType: SidebarView.tabDragType) else { return nil }
        let parts = payload.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Decodes the dragged project's offset from its pasteboard payload.
    private func draggedProject(from info: NSDraggingInfo) -> Int? {
        info.draggingPasteboard.string(forType: SidebarView.projectDragType).flatMap(Int.init)
    }

    /// Which sidebar section a project row belongs to (drives drag-reorder
    /// scoping — a row can only be reordered within its own section).
    private func section(forProjectAt index: Int) -> SidebarSection {
        guard projects.indices.contains(index) else { return .projects }
        let p = projects[index]
        if p.isHibernated { return .hibernated }
        if p.isScratch { return .scratch }
        return p.isPinned ? .pinned : .projects
    }

    /// The half-open `topLevel` index range of the project rows under `section`'s
    /// header, or nil when the section isn't currently shown.
    private func projectRowRange(for section: SidebarSection) -> Range<Int>? {
        guard let headerIdx = topLevel.firstIndex(of: .header(section)) else { return nil }
        var end = headerIdx + 1
        while end < topLevel.count, case .project = topLevel[end] { end += 1 }
        return (headerIdx + 1)..<end
    }

    /// Clamps a proposed drop gap into a section's insertion range (before its
    /// first row … after its last). A drop-on-row (`index < 0`) snaps to the end.
    private func clampProjectDrop(_ index: Int, into range: Range<Int>) -> Int {
        let proposed = index < 0 ? range.upperBound : index
        return min(max(proposed, range.lowerBound), range.upperBound)
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarView: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let obj = item as? OutlineItem else { return nil }

        switch obj.kind {
        case .header(let section):
            let identifier = NSUserInterfaceItemIdentifier("HeaderCell")
            let cellView: HeaderCellView
            if let recycled = outlineView.makeView(withIdentifier: identifier, owner: nil) as? HeaderCellView {
                cellView = recycled
            } else {
                cellView = HeaderCellView()
                cellView.identifier = identifier
            }
            let count: Int
            switch section {
            case .pinned:     count = pinnedCount
            case .projects:   count = projectsCount
            case .scratch:    count = scratchCount
            case .hibernated: count = hibernatedCount
            }
            cellView.configure(title: section.title, count: count)
            return cellView

        case .project(let p):
            guard projects.indices.contains(p) else { return nil }
            let project = projects[p]

            let identifier = NSUserInterfaceItemIdentifier("ProjectCell")
            let cellView: ProjectCellView
            if let recycled = outlineView.makeView(withIdentifier: identifier, owner: nil) as? ProjectCellView {
                cellView = recycled
            } else {
                cellView = ProjectCellView()
                cellView.identifier = identifier
            }
            cellView.configure(
                name: project.name,
                isPinned: project.isPinned,
                isActive: p == activeProject,
                agentStatus: project.status,
                toolIcon: project.icon,
                projectColor: project.projectColor,
                customGlyph: project.customGlyph,
                isHibernated: project.isHibernated,
                isScratch: project.isScratch,
                projectIndex: p,
                target: self,
                action: #selector(pinButtonClicked(_:))
            )
            return cellView

        case .tab(let p, let t):
            guard projects.indices.contains(p),
                  projects[p].tabTitles.indices.contains(t) else { return nil }
            let title = projects[p].tabTitles[t]
            let status = projects[p].tabStatuses.indices.contains(t) ? projects[p].tabStatuses[t] : nil
            let icon = projects[p].tabIcons.indices.contains(t) ? projects[p].tabIcons[t] : nil

            let identifier = NSUserInterfaceItemIdentifier("TabCell")
            let cellView: TabCellView
            if let recycled = outlineView.makeView(withIdentifier: identifier, owner: nil) as? TabCellView {
                cellView = recycled
            } else {
                cellView = TabCellView()
                cellView.identifier = identifier
            }
            cellView.configure(title: title, isActive: p == activeProject && t == activeTab, agentStatus: status, icon: icon)
            return cellView
        }
    }

    /// Section headers are labels, not selectable rows.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let obj = item as? OutlineItem else { return false }
        if case .header = obj.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("SidebarRow")
        if let recycled = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarRowView {
            return recycled
        }
        let row = SidebarRowView()
        row.identifier = identifier
        return row
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let obj = outlineView.item(atRow: row) as? OutlineItem else { return }

        switch obj.kind {
        case .header:
            break
        case .project(let p):
            onSelectProject?(p)
        case .tab(let p, let t):
            onSelectTab?(p, t)
        }
    }
}

// MARK: - HeaderCellView

/// A section header row: uppercase title on the left, count on the right.
private final class HeaderCellView: NSTableCellView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = ZTheme.chromeFont(size: 10.5, weight: .bold)
        titleLabel.textColor = ZTheme.current.fg3Color
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        countLabel.font = ZTheme.chromeFont(size: 10.5)
        countLabel.textColor = ZTheme.current.fg3Color
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func configure(title: String, count: Int) {
        // Uppercase with light letter-spacing (handoff section headers).
        titleLabel.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: ZTheme.chromeFont(size: 10.5, weight: .bold),
                .foregroundColor: ZTheme.current.fg3Color,
                .kern: 1.2,
            ]
        )
        countLabel.stringValue = "\(count)"
        countLabel.textColor = ZTheme.current.fg3Color
    }
}

// MARK: - SidebarRowView

/// Row view that renders selection using the theme (a `bg3` fill with an accent
/// left-bar), replacing AppKit's system-accent highlight so it matches Zetty's
/// accent regardless of the user's macOS accent color.
private final class SidebarRowView: NSTableRowView {

    override var isEmphasized: Bool {
        get { false }   // never use the emphasized (saturated system) selection
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let theme = ZTheme.current

        let fillRect = bounds.insetBy(dx: 4, dy: 1)
        theme.bg3Color.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 6, yRadius: 6).fill()

        let barHeight: CGFloat = 16
        let barRect = NSRect(x: 4, y: bounds.midY - barHeight / 2, width: 2.5, height: barHeight)
        theme.accentColor.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25).fill()
    }
}

// MARK: - ProjectCellView

/// A single project row: name label on the left, pin toggle button on the right.
private final class ProjectCellView: NSTableCellView {

    private let glyphView = NSImageView()
    private let toolIconView = NSImageView()
    private let nameLabel: NSTextField
    private let pinButton: NSButton
    /// Collapses the tool-logo slot when the project has none (0 width, no gap).
    private var toolIconWidth: NSLayoutConstraint!
    private var toolIconGap: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        nameLabel = NSTextField(labelWithString: "")
        pinButton = NSButton(title: "", target: nil, action: nil)

        super.init(frame: frameRect)

        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphView)

        toolIconView.imageScaling = .scaleProportionallyDown
        toolIconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolIconView)

        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = ZTheme.current.fgColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pinButton)

        toolIconWidth = toolIconView.widthAnchor.constraint(equalToConstant: 0)
        toolIconGap = nameLabel.leadingAnchor.constraint(equalTo: toolIconView.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            glyphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: 15),
            glyphView.heightAnchor.constraint(equalToConstant: 15),

            toolIconView.leadingAnchor.constraint(equalTo: glyphView.trailingAnchor, constant: 7),
            toolIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            toolIconWidth,
            toolIconView.heightAnchor.constraint(equalToConstant: 13),

            toolIconGap,
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

    func configure(name: String, isPinned: Bool, isActive: Bool, agentStatus: AgentStatus?,
                   toolIcon: NSImage? = nil, projectColor: NSColor? = nil,
                   customGlyph: String? = nil, isHibernated: Bool = false, isScratch: Bool = false,
                   projectIndex: Int, target: AnyObject, action: Selector) {
        nameLabel.stringValue = name
        // Hibernated rows read as dormant: dim text regardless of active state.
        nameLabel.textColor = isHibernated ? ZTheme.current.fg3Color
            : (isActive ? ZTheme.current.fgColor : ZTheme.current.fg2Color)

        // Single-tab projects surface the pane's tool logo on the row itself
        // (multi-tab projects show logos on their tab child rows instead).
        toolIconView.image = isHibernated ? nil : toolIcon
        toolIconView.contentTintColor = nameLabel.textColor
        toolIconWidth.constant = (toolIcon == nil || isHibernated) ? 0 : 13
        toolIconGap.constant = (toolIcon == nil || isHibernated) ? 0 : 6

        // Project glyph: a moon when hibernated; else a custom SF Symbol when
        // set, else the diamond (filled when an agent is present or active).
        // Tint precedence: agent status > project color > active accent / dim —
        // status colors carry meaning and always win.
        let hasAgent = agentStatus != nil
        let defaultGlyph = (hasAgent || isActive) ? "diamond.fill" : "diamond"
        let glyphConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if !isHibernated, let custom = customGlyph, ProjectIcon.isEmoji(custom) {
            // Emoji icons are colored glyphs — draw as-is, no template tint.
            glyphView.image = ProjectIcon.emojiImage(custom, pointSize: 13)
            glyphView.contentTintColor = nil
        } else {
            let glyphName = isHibernated ? "moon.zzz" : (customGlyph ?? defaultGlyph)
            glyphView.image = NSImage(systemSymbolName: glyphName, accessibilityDescription: "Project")?
                .withSymbolConfiguration(glyphConfig)
            glyphView.contentTintColor = isHibernated ? ZTheme.current.fg3Color
                : (agentStatusColor(agentStatus)
                    ?? projectColor
                    ?? (isActive ? ZTheme.current.accentColor : ZTheme.current.fg3Color))
        }

        // Scratch terminals can't be pinned — hide the star entirely.
        pinButton.isHidden = isScratch

        // Pinned rows use a filled accent star; unpinned rows show a dim hollow star.
        let symbolName = isPinned ? "star.fill" : "star"
        if let image = NSImage(systemSymbolName: symbolName,
                               accessibilityDescription: isPinned ? "Pinned" : "Pin") {
            pinButton.image = image
            pinButton.contentTintColor = isPinned
                ? ZTheme.current.accentColor
                : ZTheme.current.fg3Color
        } else {
            pinButton.title = isPinned ? "★" : "☆"
        }

        pinButton.tag = projectIndex
        pinButton.target = target
        pinButton.action = action
    }
}

// MARK: - TabCellView

/// A single tab child row: indented title label only.
private final class TabCellView: NSTableCellView {

    private let dot = NSView()
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    /// Collapses the logo slot when a tab has none (0 width, no gap).
    private var iconWidth: NSLayoutConstraint!
    private var iconGap: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        titleLabel = NSTextField(labelWithString: "")

        super.init(frame: frameRect)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.font = ZTheme.chromeFont(size: 12)
        titleLabel.textColor = ZTheme.current.fg2Color
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 0)
        iconGap = titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),

            iconView.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconView.heightAnchor.constraint(equalToConstant: 12),

            iconGap,
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func configure(title: String, isActive: Bool, agentStatus: AgentStatus?, icon: NSImage? = nil) {
        titleLabel.stringValue = title
        titleLabel.textColor = isActive ? ZTheme.current.fgColor : ZTheme.current.fg2Color

        iconView.image = icon
        iconView.contentTintColor = titleLabel.textColor
        iconWidth.constant = icon == nil ? 0 : 12
        iconGap.constant = icon == nil ? 0 : 6

        // Dot color: agent status when present (green/yellow/dim), else the
        // active/inactive accent. Pulse when an agent is running/needs-attention,
        // or when the tab is active with no agent.
        let dotColor = agentStatusColor(agentStatus)
            ?? (isActive ? ZTheme.current.accentColor : ZTheme.current.fg3Color)
        dot.layer?.backgroundColor = dotColor.cgColor
        let shouldPulse = (agentStatus == .running || agentStatus == .needsAttention)
            || (agentStatus == nil && isActive)
        if shouldPulse {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.55
            pulse.toValue = 1.0
            pulse.duration = 1.0
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(pulse, forKey: "pulse")
        } else {
            dot.layer?.removeAnimation(forKey: "pulse")
            dot.layer?.opacity = 1
        }
    }
}

// MARK: - SidebarResizeHandle

/// An invisible grab zone straddling the sidebar/content separator. Dragging
/// it resizes the sidebar; double-clicking resets the width. The reported
/// delta is the TOTAL mouse travel since the drag began, sign-corrected via
/// `dragDirectionSign` so "away from the sidebar's window edge" is always
/// positive (+1 when the sidebar is on the left, -1 on the right).
@MainActor
final class SidebarResizeHandle: NSView {

    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onReset: (() -> Void)?
    var dragDirectionSign: CGFloat = 1

    private var dragOriginX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        dragOriginX = event.locationInWindow.x
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?((event.locationInWindow.x - dragOriginX) * dragDirectionSign)
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        onDragEnded?()
    }
}
