import AppKit

// MARK: - SidebarProject

/// Plain data for one project row in the sidebar.
///
/// When `tabTitles.count >= 2` the project row is expandable and its children
/// are the individual tab titles.  A single-tab project is a plain leaf row.
struct SidebarProject {
    let name: String
    let isPinned: Bool
    let tabTitles: [String]   // .count >= 2 → expandable
}

// MARK: - Outline item model

/// Identity-stable wrapper used as NSOutlineView item objects.
///
/// NSOutlineView requires object identity for items, so we box a simple enum
/// in a class.  Two `OutlineItem` instances are equal iff they wrap the same
/// case with the same index values.
private final class OutlineItem: NSObject {
    enum Kind: Hashable {
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
        hasher.combine(kind)   // Kind is Hashable; distinguishes project vs tab without collisions
        return hasher.finalize()
    }
}

// MARK: - SidebarView

/// A two-level sidebar backed by an `NSOutlineView`.
///
/// Top level = projects.  A project is expandable (shows tab children) only
/// when it has 2 or more tabs.  The view is dumb — it takes plain display data
/// in and reports user actions out via closures.  No QuerttyCore import.
@MainActor
final class SidebarView: NSView {

    // MARK: - Callbacks

    /// Called with the project index when the user clicks a project row.
    var onSelectProject: ((Int) -> Void)?

    /// Called with (projectIndex, tabIndex) when the user clicks a tab child row.
    var onSelectTab: ((Int, Int) -> Void)?

    /// Called when the user clicks the "+" Add Project button.
    var onAddProject: (() -> Void)?

    /// Called with the project index when the user clicks the pin button.
    var onTogglePin: ((Int) -> Void)?

    // MARK: - Private state

    private var projects: [SidebarProject] = []
    private var activeProject: Int = -1
    private var activeTab: Int = -1

    // Item-object cache — keyed by Kind so we reuse the same object across
    // reloads (NSOutlineView uses pointer/isEqual identity for expansion state).
    private var itemCache: [OutlineItem.Kind: OutlineItem] = [:]

    // MARK: - Subviews

    private let scrollView: NSScrollView
    private let outlineView: NSOutlineView
    private let addButton: NSButton

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        outlineView = NSOutlineView()
        scrollView = NSScrollView()
        addButton = NSButton(title: "+", target: nil, action: nil)

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = QTheme.current.bg0Color.cgColor

        setupOutlineView()
        setupAddButton()
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // MARK: - Setup

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
        outlineView.indentationPerLevel = 16
        outlineView.indentationMarkerFollowsCell = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.backgroundColor = QTheme.current.bg0Color
        outlineView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = QTheme.current.bg0Color
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
        addSubview(addButton)
    }

    /// Applies theme-dependent styling to the Add-project button (re-callable
    /// on scheme change).
    private func styleAddButton() {
        if let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add project") {
            addButton.image = plus
            addButton.contentTintColor = QTheme.current.fg2Color
        }
        addButton.attributedTitle = NSAttributedString(
            string: " Add project",
            attributes: [
                .font: QTheme.monoFont(size: 12.5, weight: .medium),
                .foregroundColor: QTheme.current.fg2Color,
            ]
        )
    }

    /// Re-applies the active theme to background surfaces and the add button.
    /// Row cells recolor when the caller reloads via `update(...)`.
    func applyTheme() {
        layer?.backgroundColor = QTheme.current.bg0Color.cgColor
        outlineView.backgroundColor = QTheme.current.bg0Color
        scrollView.backgroundColor = QTheme.current.bg0Color
        styleAddButton()
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

    // MARK: - Item-object helpers

    private func item(for kind: OutlineItem.Kind) -> OutlineItem {
        if let existing = itemCache[kind] { return existing }
        let obj = OutlineItem(kind)
        itemCache[kind] = obj
        return obj
    }

    private func projectItem(at index: Int) -> OutlineItem {
        item(for: .project(index))
    }

    private func tabItem(project: Int, tab: Int) -> OutlineItem {
        item(for: .tab(project: project, tab: tab))
    }

    // MARK: - Update

    /// True while `update()` is programmatically adjusting the outline view, so
    /// `outlineViewSelectionDidChange` doesn't re-fire callbacks and cause loops.
    private var isUpdating = false

    /// Replaces the displayed data, auto-expands the active project, and
    /// highlights the active project/tab rows.
    func update(projects: [SidebarProject], activeProject: Int, activeTab: Int) {
        isUpdating = true
        defer { isUpdating = false }

        self.projects = projects
        self.activeProject = activeProject
        self.activeTab = activeTab

        // Evict stale cache entries whose indices no longer exist.
        itemCache = itemCache.filter { kind, _ in
            switch kind {
            case .project(let p):       return projects.indices.contains(p)
            case .tab(let p, let t):
                return projects.indices.contains(p)
                    && projects[p].tabTitles.indices.contains(t)
            }
        }

        outlineView.reloadData()

        // Auto-expand the active project if it is expandable.
        if projects.indices.contains(activeProject),
           projects[activeProject].tabTitles.count >= 2 {
            outlineView.expandItem(projectItem(at: activeProject))
        }

        // Select the active tab child row (or the project row for single-tab projects).
        let rowToSelect: Int
        if projects.indices.contains(activeProject),
           projects[activeProject].tabTitles.count >= 2 {
            let tabObj = tabItem(project: activeProject, tab: activeTab)
            rowToSelect = outlineView.row(forItem: tabObj)
        } else if projects.indices.contains(activeProject) {
            let projObj = projectItem(at: activeProject)
            rowToSelect = outlineView.row(forItem: projObj)
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
        onAddProject?()
    }

    @objc private func pinButtonClicked(_ sender: NSButton) {
        let projectIndex = sender.tag
        guard projects.indices.contains(projectIndex) else { return }
        onTogglePin?(projectIndex)
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarView: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            // Root level: number of projects.
            return projects.count
        }
        guard let obj = item as? OutlineItem,
              case .project(let p) = obj.kind,
              projects.indices.contains(p) else { return 0 }
        let count = projects[p].tabTitles.count
        return count >= 2 ? count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return projectItem(at: index)
        }
        guard let obj = item as? OutlineItem,
              case .project(let p) = obj.kind else {
            return projectItem(at: 0)   // fallback (should never happen)
        }
        return tabItem(project: p, tab: index)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let obj = item as? OutlineItem,
              case .project(let p) = obj.kind,
              projects.indices.contains(p) else { return false }
        return projects[p].tabTitles.count >= 2
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarView: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let obj = item as? OutlineItem else { return nil }

        switch obj.kind {
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
                projectIndex: p,
                target: self,
                action: #selector(pinButtonClicked(_:))
            )
            return cellView

        case .tab(let p, let t):
            guard projects.indices.contains(p),
                  projects[p].tabTitles.indices.contains(t) else { return nil }
            let title = projects[p].tabTitles[t]

            let identifier = NSUserInterfaceItemIdentifier("TabCell")
            let cellView: TabCellView
            if let recycled = outlineView.makeView(withIdentifier: identifier, owner: nil) as? TabCellView {
                cellView = recycled
            } else {
                cellView = TabCellView()
                cellView.identifier = identifier
            }
            cellView.configure(title: title)
            return cellView
        }
    }

    /// Draw selection with a themed row view instead of the OS's system accent
    /// highlight (which clashes with quertty's accent).
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
        case .project(let p):
            onSelectProject?(p)
        case .tab(let p, let t):
            onSelectTab?(p, t)
        }
    }
}

// MARK: - SidebarRowView

/// Row view that renders selection using the theme (a `bg3` fill with an accent
/// left-bar), replacing AppKit's system-accent highlight so it matches quertty's
/// accent regardless of the user's macOS accent color.
private final class SidebarRowView: NSTableRowView {

    override var isEmphasized: Bool {
        get { false }   // never use the emphasized (saturated system) selection
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let theme = QTheme.current

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

    private let nameLabel: NSTextField
    private let pinButton: NSButton

    override init(frame frameRect: NSRect) {
        nameLabel = NSTextField(labelWithString: "")
        pinButton = NSButton(title: "", target: nil, action: nil)

        super.init(frame: frameRect)

        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = QTheme.current.fgColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pinButton)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
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

    func configure(name: String, isPinned: Bool, projectIndex: Int,
                   target: AnyObject, action: Selector) {
        nameLabel.stringValue = name

        // Pinned rows use a filled accent star (matching the handoff); unpinned
        // rows show a dim hollow star affordance.
        let symbolName = isPinned ? "star.fill" : "star"
        if let image = NSImage(systemSymbolName: symbolName,
                               accessibilityDescription: isPinned ? "Pinned" : "Pin") {
            pinButton.image = image
            pinButton.contentTintColor = isPinned
                ? QTheme.current.accentColor
                : QTheme.current.fg3Color
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

    private let titleLabel: NSTextField

    override init(frame frameRect: NSRect) {
        titleLabel = NSTextField(labelWithString: "")

        super.init(frame: frameRect)

        titleLabel.font = QTheme.monoFont(size: 12)
        titleLabel.textColor = QTheme.current.fg2Color
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func configure(title: String) {
        titleLabel.stringValue = title
    }
}
