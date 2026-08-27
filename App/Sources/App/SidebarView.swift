import AppKit
import ZettyGhostty

// MARK: - SidebarProject

/// Plain data for one project row in the sidebar.
///
/// When `tabTitles.count >= 2` the project row is expandable and its children
/// are the individual tab titles.  A single-tab project is a plain leaf row.
/// Equatable so `SidebarView.update` can skip identical reloads — agent status
/// and title ticks arrive several times a second and most leave every row
/// unchanged. `NSImage`/`NSColor` compare by `isEqual:`, and `AgentIcons` caches
/// its logos, so an unchanged icon is the same instance.
struct SidebarProject: Equatable {
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
    let isHome: Bool                     // permanent Home project (own top section)
    let isClone: Bool                    // renders attached under its source with a fork glyph
    let cloneSourceIndex: Int?           // index of the source project (nil → orphan)
    let isPendingClone: Bool             // transient "Cloning…" placeholder: spinner glyph, non-interactive
    let spaceID: UUID?                   // the Space this row renders under, nil for Pinned/Projects
    let spaceName: String?               // that Space's name — tags a hibernated row with where it will return
    let accountColor: NSColor?           // project's DEFAULT agent account (nil = the default login)
    let accountName: String?             // that account's name, for the row's tooltip
    let tabAccountColors: [NSColor?]     // parallel to tabTitles; nil = the default login
}

/// Plain data for one Space header row: identity and appearance only. Counts
/// are NOT carried here — they must reflect the current filter, so
/// `rebuildOutline()` derives them from its own filtered member lists (the
/// same path every other section's count already takes). A second count
/// source on this struct is exactly what let a Space header show stale
/// pre-filter numbers. Equatable for the same reason `SidebarProject` is:
/// machine-driven refreshes arrive several times a second and must no-op on
/// unchanged input.
struct SidebarSpace: Equatable {
    let id: UUID
    let name: String
    let color: NSColor?          // resolved from ZTheme.projectPalette (nil = default)
    let glyph: String?           // SF Symbol overriding the default header glyph
    let isCollapsed: Bool
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
    case home
    case pinned
    case projects
    case scratch
    case hibernated
    case space(UUID)

    func title(spaces: [SidebarSpace]) -> String {
        switch self {
        case .home:       return "Home"
        case .pinned:     return "Pinned"
        case .projects:   return "Projects"
        case .scratch:    return "Scratch"
        case .hibernated: return "Hibernating"
        case .space(let id):
            return spaces.first { $0.id == id }?.name ?? "Space"
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

    /// Called when a Space header's disclosure is clicked. Collapse state is
    /// persisted, so the controller writes it to the model and refreshes.
    var onToggleSpaceCollapsed: ((UUID) -> Void)?

    /// Called when a Space header is drag-reordered: (fromSpaceIndex, toSpaceIndex).
    var onMoveSpace: ((Int, Int) -> Void)?

    /// Called to move a project into a Space (nil = out of every Space).
    var onAssignProjectToSpace: ((Int, UUID?) -> Void)?

    /// Called from a project row's "Move to Space ▸ New Space…" with the
    /// project index to file into the new Space once created, or nil when
    /// invoked from a Space header instead.
    var onNewSpace: ((Int?) -> Void)?

    /// Called with a Space's id for its header context menu's "Rename…" and
    /// "Edit Space…" (both open the same sheet — the sheet's name field
    /// covers renaming).
    var onEditSpace: ((UUID) -> Void)?

    /// Called with a Space's id for its header context menu's "Delete Space…".
    var onDeleteSpace: ((UUID) -> Void)?

    /// Called with a Space's id for its header context menu's "Hibernate All"
    /// (true) / "Wake All" (false).
    var onHibernateSpace: ((UUID, Bool) -> Void)?

    /// Called with the project index when the user picks "Remove Project…"
    /// from a project row's context menu.
    var onRemoveProject: ((Int) -> Void)?

    /// Called with the project index for the context menu's "Clone Project…".
    var onCloneProject: ((Int) -> Void)?

    /// Called with the project index for the context menu's "Merge to Source…".
    var onMergeToSource: ((Int) -> Void)?

    /// Called with the project index for the context menu's "Rename…".
    var onRenameProject: ((Int) -> Void)?
    var onToggleHibernate: ((Int) -> Void)?

    /// Called with the project index for the context menu's "Project Settings…".
    var onOpenProjectSettings: ((Int) -> Void)?

    // MARK: - Private state

    /// The full (unfiltered) project list as last received, pinned-first sorted.
    private var projects: [SidebarProject] = []
    private var spaces: [SidebarSpace] = []
    private var activeProject: Int = -1
    private var activeTab: Int = -1

    /// Current filter text (case-insensitive substring on project name).
    private var filterText: String = ""

    /// True while a tab or project row is being drag-reordered — freezes
    /// `update(...)` reloads, which would cancel the outline view's drag session.
    private var isReordering = false

    /// The top-level rows currently displayed (headers + visible projects).
    private var topLevel: [OutlineItem.Kind] = []
    private var homeCount = 0
    private var pinnedCount = 0
    private var projectsCount = 0
    private var scratchCount = 0
    private var hibernatedCount = 0
    /// Per-Space (awake, hibernated) member counts, computed from the same
    /// FILTERED member lists used to build that Space's rows — never from
    /// `SidebarSpace` (which carries no counts) or the unfiltered model.
    private var spaceCounts: [UUID: (awake: Int, hibernated: Int)] = [:]

    /// Whether the Hibernating section is collapsed (its dormant project rows
    /// hidden). Transient — resets to expanded on relaunch, like zoom.
    private var hibernatedCollapsed = false

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
        outlineView.registerForDraggedTypes(
            [SidebarView.tabDragType, SidebarView.projectDragType, SidebarView.spaceDragType])
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

    /// Bell count the button currently reflects, so re-publishing an unchanged
    /// count doesn't re-set `attributedTitle` (an AppKit KVO leak per
    /// assignment) or build another symbol image. Reset by `applyTheme()`.
    private var renderedBellCount: Int?

    private func styleBellButton() {
        guard renderedBellCount != attentionCount else { return }
        renderedBellCount = attentionCount
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
        renderedBellCount = nil   // same count, different colors
        styleBellButton()
        styleGearButton()
        styleTopAddButton()
        // Row views take their colors from the theme at build time, and
        // `update(...)` now skips reloads when the data is unchanged — so a
        // scheme switch has to rebuild the rows itself or they keep the old
        // palette. The selection hasn't moved, so this won't touch the scroller.
        rebuildOutline()
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

    /// The logical selection the outline was last scrolled to, so a pure
    /// re-render doesn't move the scroller (see `rebuildOutline`).
    private struct Selection: Equatable {
        let project: Int
        let tab: Int
    }
    private var lastScrolledSelection: Selection?

    /// False until the first `update(...)` lands, so the initial render can't be
    /// mistaken for "unchanged" by the equality guard (an empty workspace really
    /// does equal the initial empty state).
    private var hasRenderedOnce = false

    /// Replaces the displayed data, then rebuilds the sectioned outline.
    func update(projects: [SidebarProject], spaces: [SidebarSpace],
                activeProject: Int, activeTab: Int) {
        // Reloading mid-drag cancels the outline view's drag session (live
        // agents retitle rows every second) — freeze until the drop lands.
        guard !isReordering else { return }
        // Identical data → nothing to do. `reloadData()` recreates every row
        // view and dirties the whole layout tree, and this is called on every
        // agent title/status tick.
        if projects == self.projects, spaces == self.spaces, activeProject == self.activeProject,
           activeTab == self.activeTab, hasRenderedOnce {
            return
        }
        hasRenderedOnce = true
        self.projects = projects
        self.spaces = spaces
        self.activeProject = activeProject
        self.activeTab = activeTab
        rebuildOutline()
    }

    /// Toggles the Hibernating section's collapsed state and rebuilds.
    private func toggleHibernatedCollapsed() {
        hibernatedCollapsed.toggle()
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
        // Sections: Home · Pinned · Spaces · Projects · Scratch · Hibernating.
        // Home always sits first in its own section (even when hibernated — it
        // dims in place rather than moving to Hibernating). Scratch terminals
        // (project-less, ephemeral) get their own group; other hibernated
        // projects sit at the bottom regardless of pin state.
        let home = visible.filter { $0.element.isHome }
        let rest = visible.filter { !$0.element.isHome }
        // A member of a Space stays in its Space when hibernated — dimmed in
        // place, EVERY hibernated project collects in the Hibernating section,
        // Space members included. Membership is kept (`spaceID` is untouched),
        // so waking one returns it to its Space — or to Projects when it has
        // none. Sorted by name: display order only, real indices preserved.
        let hibernated = rest.filter { $0.element.isHibernated }
            .sorted { $0.element.name.localizedCaseInsensitiveCompare($1.element.name) == .orderedAscending }
        let placed = rest.filter { !$0.element.isHibernated }
        let scratch = placed.filter { $0.element.isScratch }
        let regular = placed.filter { !$0.element.isScratch }
        // A clone with a visible, awake source renders attached — spliced in right
        // after its source row, not counted in section headers. Orphans (source
        // removed) and clones of hidden/hibernated sources fall back to ordinary rows.
        let regularOffsets = Set(regular.map(\.offset))
        let attachedClones = regular.filter { entry in
            guard entry.element.isClone, let s = entry.element.cloneSourceIndex else { return false }
            return regularOffsets.contains(s)
        }
        let attachedOffsets = Set(attachedClones.map(\.offset))
        let standalone = regular.filter { !attachedOffsets.contains($0.offset) }
        let pinned = standalone.filter { $0.element.isPinned && $0.element.spaceID == nil }
        let unpinned = standalone.filter { !$0.element.isPinned && $0.element.spaceID == nil }
        func members(of spaceID: UUID) -> [(offset: Int, element: SidebarProject)] {
            standalone.filter { $0.element.spaceID == spaceID }
        }
        homeCount = home.count
        pinnedCount = pinned.count
        projectsCount = unpinned.count
        scratchCount = scratch.count
        hibernatedCount = hibernated.count

        // Each source row is immediately followed by its attached clone rows.
        func withClones(_ entries: [(offset: Int, element: SidebarProject)]) -> [OutlineItem.Kind] {
            entries.flatMap { entry -> [OutlineItem.Kind] in
                [.project(entry.offset)] + attachedClones
                    .filter { $0.element.cloneSourceIndex == entry.offset }
                    .map { .project($0.offset) }
            }
        }

        var rows: [OutlineItem.Kind] = []
        // Home renders as a single row at the very top — no section header.
        rows += home.map { .project($0.offset) }
        if !pinned.isEmpty {
            rows.append(.header(.pinned))
            rows += withClones(pinned)
        }
        if !unpinned.isEmpty {
            rows.append(.header(.projects))
            rows += withClones(unpinned)
        }
        // Spaces sit below Projects, in their own order. A Space
        // header is shown even with no members, so a freshly created Space is
        // visible and can be dropped onto.
        spaceCounts.removeAll(keepingCapacity: true)
        for space in spaces {
            let spaceMembers = members(of: space.id)
            // Counted from the same FILTERED list its rows come from, so the
            // header's number always matches what's actually shown under it.
            // Awake count comes from the rows actually rendered; the dormant
            // count from the filtered hibernated list, since those rows now live
            // under Hibernating. Both derive from `visible`, so a search filter
            // still narrows them together.
            spaceCounts[space.id] = (
                awake: spaceMembers.count,
                hibernated: hibernated.filter { $0.element.spaceID == space.id }.count
            )
            // A Space with no AWAKE members renders nothing — its dormant
            // projects are listed under Hibernating (tagged with its name), and
            // an empty section header is just noise. It stays reachable from
            // `Move to Space ▸`, which lists Spaces from the model.
            guard !spaceMembers.isEmpty else { continue }
            rows.append(.header(.space(space.id)))
            if !space.isCollapsed {
                rows += withClones(spaceMembers)
            }
        }
        if !scratch.isEmpty {
            rows.append(.header(.scratch))
            rows += scratch.map { .project($0.offset) }
        }
        if !hibernated.isEmpty {
            rows.append(.header(.hibernated))
            if !hibernatedCollapsed {
                rows += hibernated.map { .project($0.offset) }
            }
        }
        topLevel = rows

        // A collapsed Space still renders its active member — an invisible
        // selection would be worse than an extra row. Gated on the active
        // project actually passing the filter (matching every other section,
        // which derives visibility from `visible`) — otherwise a filter that
        // hides it would still force its row to appear.
        //
        // The active row's EFFECTIVE Space is its own spaceID, or — when it's
        // a clone (always spaceID == nil, since assign refuses clones) — its
        // clone source's spaceID, the same rule `withClones` uses to glue a
        // clone under its source's header. Skipping this falls back to the
        // clone's own nil spaceID, so a Space collapsed while a clone inside
        // it is active would insert nothing and leave the sidebar with no
        // selected row at all.
        if activeProject >= 0, projects.indices.contains(activeProject),
           visible.contains(where: { $0.offset == activeProject }) {
            let active = projects[activeProject]
            let effectiveSpaceID = active.spaceID
                ?? active.cloneSourceIndex.flatMap { projects.indices.contains($0) ? projects[$0].spaceID : nil }
            if let spaceID = effectiveSpaceID,
               spaces.first(where: { $0.id == spaceID })?.isCollapsed == true,
               let headerIndex = topLevel.firstIndex(of: .header(.space(spaceID))) {
                topLevel.insert(.project(activeProject), at: headerIndex + 1)
            }
        }

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
            // Only chase the selection when it actually MOVED. A rebuild driven
            // by an agent retitling its tab must never touch the scroller —
            // doing so yanked the sidebar back to the active project several
            // times a second, which made it impossible to scroll anywhere else.
            // Keyed on the logical selection, not the row index: rows shift when
            // a section collapses or a project hibernates without the user's
            // selection having moved at all.
            let selection = Selection(project: activeProject, tab: activeTab)
            if lastScrolledSelection != selection {
                outlineView.scrollRowToVisible(rowToSelect)
                lastScrolledSelection = selection
            }
        } else {
            outlineView.deselectAll(nil)
            lastScrolledSelection = nil
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

    @objc private func cloneProjectMenuClicked(_ sender: NSMenuItem) {
        let projectIndex = sender.tag
        guard projects.indices.contains(projectIndex) else { return }
        onCloneProject?(projectIndex)
    }

    @objc private func mergeToSourceMenuClicked(_ sender: NSMenuItem) {
        let projectIndex = sender.tag
        guard projects.indices.contains(projectIndex) else { return }
        onMergeToSource?(projectIndex)
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

    @objc private func assignSpaceMenuClicked(_ sender: NSMenuItem) {
        onAssignProjectToSpace?(sender.tag, sender.representedObject as? UUID)
    }

    @objc private func newSpaceMenuClicked(_ sender: NSMenuItem) {
        onNewSpace?(sender.tag)
    }

    @objc private func collapseSpaceMenuClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onToggleSpaceCollapsed?(id)
    }

    @objc private func renameSpaceMenuClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onEditSpace?(id)
    }

    @objc private func editSpaceMenuClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onEditSpace?(id)
    }

    @objc private func hibernateSpaceMenuClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onHibernateSpace?(id, true)
    }

    @objc private func wakeSpaceMenuClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onHibernateSpace?(id, false)
    }

    @objc private func deleteSpaceMenuClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onDeleteSpace?(id)
    }
}

// MARK: - NSMenuDelegate (project row context menu)

extension SidebarView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let obj = outlineView.item(atRow: row) as? OutlineItem else { return }

        if case .header(.space(let id)) = obj.kind, spaces.contains(where: { $0.id == id }) {
            // Collapse lives here as well as on the chevron: a Space header is
            // draggable, so its click target is the chevron alone rather than
            // the whole row, and that is a small thing to hit.
            let isCollapsed = spaces.first { $0.id == id }?.isCollapsed ?? false
            let collapse = NSMenuItem(title: isCollapsed ? "Expand" : "Collapse",
                                      action: #selector(collapseSpaceMenuClicked(_:)),
                                      keyEquivalent: "")
            collapse.target = self
            collapse.representedObject = id
            menu.addItem(collapse)
            menu.addItem(.separator())

            for (title, selector) in [("Rename\u{2026}", #selector(renameSpaceMenuClicked(_:))),
                                      ("Edit Space\u{2026}", #selector(editSpaceMenuClicked(_:)))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self
                item.representedObject = id
                menu.addItem(item)
            }
            menu.addItem(.separator())
            // Counts come from `spaceCounts` (the filtered member list), never
            // from `SidebarSpace` — see its doc comment for why.
            let awake = spaceCounts[id]?.awake ?? 0
            let hibernated = spaceCounts[id]?.hibernated ?? 0

            let hibernate = NSMenuItem(title: "Hibernate All",
                                       action: #selector(hibernateSpaceMenuClicked(_:)),
                                       keyEquivalent: "")
            hibernate.target = self
            hibernate.representedObject = id
            hibernate.isEnabled = awake > 0
            menu.addItem(hibernate)

            let wake = NSMenuItem(title: "Wake All", action: #selector(wakeSpaceMenuClicked(_:)),
                                  keyEquivalent: "")
            wake.target = self
            wake.representedObject = id
            wake.isEnabled = hibernated > 0
            menu.addItem(wake)

            menu.addItem(.separator())
            let delete = NSMenuItem(title: "Delete Space\u{2026}",
                                    action: #selector(deleteSpaceMenuClicked(_:)),
                                    keyEquivalent: "")
            delete.target = self
            delete.representedObject = id
            menu.addItem(delete)
            return
        }

        guard case .project(let p) = obj.kind, projects.indices.contains(p) else { return }
        // A "Cloning…" placeholder has no actions until the copy lands.
        guard !projects[p].isPendingClone else { return }

        let isScratch = projects[p].isScratch
        let isHome = projects[p].isHome

        let rename = NSMenuItem(title: "Rename\u{2026}",
                                action: #selector(renameProjectMenuClicked(_:)),
                                keyEquivalent: "")
        rename.target = self
        rename.tag = p
        menu.addItem(rename)

        // Scratch terminals are project-less and ephemeral: no per-project
        // settings and no hibernation. Clones have no settings either — they
        // inherit the source project's (a settings file of their own would
        // break that inheritance).
        if !isScratch {
            if !projects[p].isClone {
                let settings = NSMenuItem(title: "Project Settings\u{2026}",
                                          action: #selector(projectSettingsMenuClicked(_:)),
                                          keyEquivalent: "")
                settings.target = self
                settings.tag = p
                menu.addItem(settings)
            }

            // Home, scratch terminals, and clones are never Space members —
            // hide the item entirely rather than offering a move the model
            // will refuse (a clone follows its source's Space).
            if !isHome && !projects[p].isClone {
                let moveItem = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
                let submenu = NSMenu()

                let none = NSMenuItem(title: "None", action: #selector(assignSpaceMenuClicked(_:)),
                                      keyEquivalent: "")
                none.target = self
                none.tag = p
                none.representedObject = nil as UUID?
                none.state = projects[p].spaceID == nil ? .on : .off
                submenu.addItem(none)

                if !spaces.isEmpty { submenu.addItem(.separator()) }
                for space in spaces {
                    let item = NSMenuItem(title: space.name,
                                          action: #selector(assignSpaceMenuClicked(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.tag = p
                    item.representedObject = space.id
                    item.state = projects[p].spaceID == space.id ? .on : .off
                    submenu.addItem(item)
                }

                submenu.addItem(.separator())
                let newSpace = NSMenuItem(title: "New Space\u{2026}",
                                          action: #selector(newSpaceMenuClicked(_:)),
                                          keyEquivalent: "")
                newSpace.target = self
                newSpace.tag = p
                submenu.addItem(newSpace)

                moveItem.submenu = submenu
                menu.addItem(moveItem)
            }

            let hibernate = NSMenuItem(
                title: projects[p].isHibernated ? "Wake Project" : "Hibernate Project",
                action: #selector(hibernateMenuClicked(_:)), keyEquivalent: "")
            hibernate.target = self
            hibernate.tag = p
            menu.addItem(hibernate)

            if !isHome && !projects[p].isClone {
                let clone = NSMenuItem(title: "Clone Project\u{2026}",
                                       action: #selector(cloneProjectMenuClicked(_:)),
                                       keyEquivalent: "")
                clone.target = self
                clone.tag = p
                menu.addItem(clone)
            }

            if projects[p].isClone {
                let merge = NSMenuItem(title: "Merge to Source\u{2026}",
                                       action: #selector(mergeToSourceMenuClicked(_:)),
                                       keyEquivalent: "")
                merge.target = self
                merge.tag = p
                menu.addItem(merge)
            }
        }

        // Home is permanent — it offers settings/hibernation but no removal.
        if !isHome {
            menu.addItem(.separator())

            let removeTitle = isScratch ? "Close Terminal"
                : projects[p].isClone ? "Remove Clone\u{2026}" : "Remove Project\u{2026}"
            let remove = NSMenuItem(title: removeTitle,
                                    action: #selector(removeProjectMenuClicked(_:)),
                                    keyEquivalent: "")
            remove.target = self
            remove.tag = p
            menu.addItem(remove)   // Home is the floor, so any other project is removable
        }
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
        // Hibernated projects are dormant leaf rows — no tab children. Home is
        // always a single collapsed row (tabs still work, just not listed here).
        if projects[p].isHibernated || projects[p].isHome { return 0 }
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
        return !projects[p].isHibernated && !projects[p].isHome && projects[p].tabTitles.count >= 2
    }

    // MARK: Drag-reorder (tab children within a project · project rows within a section)

    static let tabDragType = NSPasteboard.PasteboardType("co.webteractive.zetty.sidebar-tab")
    static let projectDragType = NSPasteboard.PasteboardType("co.webteractive.zetty.sidebar-project")
    static let spaceDragType = NSPasteboard.PasteboardType("co.webteractive.zetty.sidebar-space")

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let obj = item as? OutlineItem else { return nil }
        switch obj.kind {
        case .tab(let project, let tab):
            let pb = NSPasteboardItem()
            pb.setString("\(project):\(tab)", forType: SidebarView.tabDragType)
            return pb
        case .project(let p):
            // No project drag while filtering (visible rows are a subset, so
            // offsets don't map to neighbours), for hibernated rows (that
            // section isn't reorderable), or for "Cloning…" placeholders.
            guard filterText.trimmingCharacters(in: .whitespaces).isEmpty,
                  projects.indices.contains(p), !projects[p].isHibernated,
                  !projects[p].isPendingClone else { return nil }
            let pb = NSPasteboardItem()
            pb.setString("\(p)", forType: SidebarView.projectDragType)
            return pb
        case .header(.space(let id)):
            // Same filter guard as a project drag: visible rows (incl. header
            // positions) are a subset while filtering, so offsets don't map.
            guard filterText.trimmingCharacters(in: .whitespaces).isEmpty,
                  let index = spaces.firstIndex(where: { $0.id == id }) else { return nil }
            let pb = NSPasteboardItem()
            pb.setString("\(index)", forType: SidebarView.spaceDragType)
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
        // Space header: reorder within the Spaces band only.
        if let from = draggedSpace(from: info) {
            guard spaces.indices.contains(from) else { return [] }
            return validateSpaceDrop(from, item: item, index: index, outlineView: outlineView)
        }

        // Tab child: only between the SAME project's tab children (never onto a row).
        if let source = draggedTab(from: info) {
            guard index >= 0,
                  let obj = item as? OutlineItem,
                  case .project(let targetProject) = obj.kind,
                  targetProject == source.project else { return [] }
            return .move
        }

        // Project row: within its own section, OR onto a Space header / into a
        // different section's row range — Space assignment, the only
        // cross-section drop Zetty allows (the pinned-first invariant depends
        // on every other cross-section drop staying refused).
        guard let from = draggedProject(from: info), projects.indices.contains(from) else { return [] }

        // Drop ONTO a Space header → assign to that Space. Only when the model
        // would actually accept it — `WorkspaceModel.assign(projectAt:to:)`
        // refuses Home, Scratch, and clones, and a drop that looks accepted
        // but silently does nothing is worse than one with no drop target.
        if let obj = item as? OutlineItem, case .header(.space) = obj.kind, isSpaceAssignable(from) {
            return .move
        }

        let current = section(forProjectAt: from)
        guard let range = projectRowRange(for: current) else { return [] }

        // Drop into a GAP (item == nil) that belongs to a different, eligible
        // section → assignment/ungroup. Leave the indicator where it is; the
        // gap is already a valid position in the target section. Mirrors
        // acceptDrop exactly: a .space gap always assigns, but a .pinned/
        // .projects gap only ungroups — it does nothing when the dragged row
        // is already spaceless, so the indicator must not claim otherwise.
        if item == nil, isSpaceAssignable(from),
           let gapSection = section(forTopLevelGap: index), gapSection != current {
            switch gapSection {
            case .space:
                return .move
            case .pinned, .projects:
                if case .space = current {
                    return .move
                }
            default:
                break
            }
        }

        // Otherwise: clamp/snap to stay inside the dragged row's own section.
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
        // Space header move.
        if let from = draggedSpace(from: info) {
            guard spaces.indices.contains(from) else { return false }
            // The drop gap counts the dragged row's own old slot when moving
            // down, exactly as in the project- and tab-move branches below.
            let gap = spaceIndexForGap(index < 0 ? topLevel.count : index)
            let to = gap > from ? gap - 1 : gap
            guard to != from, spaces.indices.contains(to) else { return false }
            isReordering = false
            onMoveSpace?(from, to)
            return true
        }

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

        // Project row: assignment (Space header / cross-section gap) first,
        // then the existing within-section reorder.
        guard let from = draggedProject(from: info), projects.indices.contains(from) else { return false }
        let current = section(forProjectAt: from)

        let target: SidebarSection?
        if let obj = item as? OutlineItem, case .header(let section) = obj.kind {
            target = section
        } else {
            target = section(forTopLevelGap: index < 0 ? topLevel.count : index)
        }
        if let target, target != current, isSpaceAssignable(from) {
            switch target {
            case .space(let id):
                isReordering = false
                onAssignProjectToSpace?(from, id)
                return true
            case .pinned, .projects:
                // Dropping out of a Space ungroups; pin state is untouched.
                if case .space = current {
                    isReordering = false
                    onAssignProjectToSpace?(from, nil)
                    return true
                }
            default:
                return false
            }
        }

        // Project row move within a section.
        guard let range = projectRowRange(for: current) else { return false }
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

    /// Decodes the dragged Space's index (into `spaces`) from its pasteboard payload.
    private func draggedSpace(from info: NSDraggingInfo) -> Int? {
        info.draggingPasteboard.string(forType: SidebarView.spaceDragType).flatMap(Int.init)
    }

    /// Mirrors `WorkspaceModel.assign(projectAt:to:)`'s refusals: Home, Scratch,
    /// and clones can never join or leave a Space. The drag layer must not
    /// offer a drop the model will reject — a drop that looks accepted but
    /// silently does nothing is worse than no drop target at all.
    private func isSpaceAssignable(_ index: Int) -> Bool {
        guard projects.indices.contains(index) else { return false }
        let p = projects[index]
        return !p.isHome && !p.isScratch && !p.isClone
    }

    /// Which sidebar section a project row belongs to (drives drag-reorder
    /// scoping — a row can only be reordered within its own section).
    private func section(forProjectAt index: Int) -> SidebarSection {
        guard projects.indices.contains(index) else { return .projects }
        let p = projects[index]
        if p.isHome { return .home }
        // A Space member's section follows it even when hibernated (dimmed in
        // place), matching how rebuildOutline() places its row.
        if let spaceID = p.spaceID { return .space(spaceID) }
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

    /// The section whose row range contains `gap`, or nil when the gap sits at
    /// a boundary owned by no section (e.g. before the very first row).
    private func section(forTopLevelGap gap: Int) -> SidebarSection? {
        for kind in topLevel.prefix(gap).reversed() {
            if case .header(let section) = kind { return section }
            if case .project(let offset) = kind, projects.indices.contains(offset) {
                return section(forProjectAt: offset)
            }
        }
        return nil
    }

    /// The half-open `topLevel` range spanning the Spaces band — every Space
    /// header plus its member rows, from the first Space header through the
    /// last Space's last row — or nil when no Spaces are shown. This is the
    /// only place a dragged Space header may be dropped.
    private var spacesBandRange: Range<Int>? {
        guard let first = topLevel.firstIndex(where: {
            if case .header(.space) = $0 { return true }
            return false
        }) else { return nil }
        var end = first
        for kind in topLevel[first...] {
            switch kind {
            case .header(.space), .project:
                end += 1
            case .tab:
                // `topLevel` only ever holds `.header`/`.project` kinds — a
                // `.tab` can't appear here. Listed explicitly (rather than
                // folded into `default`) so a future `Kind` case fails to
                // compile here instead of silently matching this arm.
                return first..<end
            case .header:
                // A non-space header ends the band.
                return first..<end
            }
        }
        return first..<end
    }

    /// Maps a `topLevel` drop gap to a target index in the `spaces` array, by
    /// counting the Space headers that precede it. Only meaningful within
    /// `spacesBandRange`.
    private func spaceIndexForGap(_ gap: Int) -> Int {
        topLevel.prefix(gap).reduce(into: 0) { count, kind in
            if case .header(.space) = kind { count += 1 }
        }
    }

    /// Validates (and visually snaps) a dragged Space header's drop: only
    /// inside the Spaces band, and only at a Space-header boundary — dropping
    /// in the middle of another Space's member rows still reorders headers,
    /// it just snaps to the nearest one rather than pointing into a member list.
    private func validateSpaceDrop(
        _ from: Int, item: Any?, index: Int, outlineView: NSOutlineView
    ) -> NSDragOperation {
        guard filterText.trimmingCharacters(in: .whitespaces).isEmpty,
              let band = spacesBandRange, !band.isEmpty else { return [] }
        let headerIndices = topLevel[band].indices.filter {
            if case .header(.space) = topLevel[$0] { return true }
            return false
        }
        let snapPoints = headerIndices + [band.upperBound]
        let proposed = index < 0 ? band.upperBound : index
        let clamped = min(max(proposed, band.lowerBound), band.upperBound)
        let nearest = snapPoints.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? band.lowerBound
        if item != nil || index != nearest {
            outlineView.setDropItem(nil, dropChildIndex: nearest)
        }
        return .move
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
            var dormant = 0
            var collapsible = false
            var collapsed = false
            var accent: NSColor?
            var symbol: String?
            var draggable = false
            var onToggle: (() -> Void)?
            switch section {
            case .home:       count = homeCount
            case .pinned:     count = pinnedCount
            case .projects:   count = projectsCount
            case .scratch:    count = scratchCount
            case .hibernated:
                count = hibernatedCount
                collapsible = true
                collapsed = hibernatedCollapsed
                onToggle = { [weak self] in self?.toggleHibernatedCollapsed() }
            case .space(let id):
                let space = spaces.first { $0.id == id }
                // Counts come from `spaceCounts` (computed in rebuildOutline
                // from the FILTERED member list), never from `space` itself —
                // `SidebarSpace` carries no counts precisely so there is only
                // one source of truth for this number.
                count = spaceCounts[id]?.awake ?? 0
                dormant = spaceCounts[id]?.hibernated ?? 0
                collapsible = true
                collapsed = space?.isCollapsed ?? false
                accent = space?.color
                // A color dot by default; a custom glyph overrides it. Other
                // sections leave `symbol` nil, which hides the slot entirely.
                symbol = space?.glyph ?? "circle.fill"
                // Only Space headers can be dragged (to reorder Spaces), so
                // only they give up the full-bleed click target.
                draggable = true
                onToggle = { [weak self] in self?.onToggleSpaceCollapsed?(id) }
            }
            cellView.configure(
                title: section.title(spaces: spaces),
                count: count,
                dormant: dormant,
                collapsible: collapsible,
                collapsed: collapsed,
                accent: accent,
                symbol: symbol,
                draggable: draggable,
                onToggle: onToggle
            )
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
                customGlyph: project.customGlyph ?? (project.isClone ? "arrow.triangle.branch" : nil),
                isHibernated: project.isHibernated,
                isScratch: project.isScratch,
                isClone: project.isClone,
                isHome: project.isHome,
                inSpace: project.spaceID != nil,
                spaceName: project.spaceName,
                isPendingClone: project.isPendingClone,
                accountColor: project.accountColor,
                accountName: project.accountName,
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
            let accountColor = projects[p].tabAccountColors.indices.contains(t)
                ? projects[p].tabAccountColors[t] : nil

            let identifier = NSUserInterfaceItemIdentifier("TabCell")
            let cellView: TabCellView
            if let recycled = outlineView.makeView(withIdentifier: identifier, owner: nil) as? TabCellView {
                cellView = recycled
            } else {
                cellView = TabCellView()
                cellView.identifier = identifier
            }
            cellView.configure(title: title, isActive: p == activeProject && t == activeTab,
                               agentStatus: status, icon: icon, accountColor: accountColor)
            return cellView
        }
    }

    /// Section headers are labels, not selectable rows.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let obj = item as? OutlineItem else { return false }
        if case .header = obj.kind { return false }
        // "Cloning…" placeholders aren't real projects yet — not selectable.
        if case .project(let p) = obj.kind,
           projects.indices.contains(p), projects[p].isPendingClone { return false }
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
/// A collapsible section (Hibernating) also shows a leading disclosure chevron
/// and captures clicks anywhere in the row via a transparent overlay button.
private final class HeaderCellView: NSTableCellView {

    /// Leading disclosure chevron, shown only for collapsible sections.
    private let chevronView = NSImageView()
    /// Space identity glyph — a plain color dot by default, an SF Symbol when
    /// the Space has a custom one. Hidden for every other section.
    private let glyphView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    /// Full-bleed transparent button that toggles a collapsible section — a
    /// button (not a gesture recognizer) so clicks land reliably inside the
    /// outline view, mirroring the project row's pin button.
    private let toggleButton = NSButton()
    private var toggleFullWidth: NSLayoutConstraint!
    private var toggleChevronWidth: NSLayoutConstraint!
    private var chevronWidth: NSLayoutConstraint!
    private var chevronGap: NSLayoutConstraint!
    private var glyphWidth: NSLayoutConstraint!
    private var glyphGap: NSLayoutConstraint!
    private var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        chevronView.imageScaling = .scaleProportionallyDown
        chevronView.contentTintColor = ZTheme.current.fg3Color
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronView)

        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphView)

        titleLabel.font = ZTheme.chromeFont(size: 10.5, weight: .bold)
        titleLabel.textColor = ZTheme.current.fg3Color
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        countLabel.font = ZTheme.chromeFont(size: 10.5)
        countLabel.textColor = ZTheme.current.fg3Color
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        toggleButton.title = ""
        toggleButton.isBordered = false
        toggleButton.setButtonType(.momentaryChange)
        toggleButton.focusRingType = .none
        toggleButton.target = self
        toggleButton.action = #selector(toggleClicked)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggleButton)   // topmost — captures clicks, draws nothing

        chevronWidth = chevronView.widthAnchor.constraint(equalToConstant: 0)
        chevronGap = glyphView.leadingAnchor.constraint(equalTo: chevronView.trailingAnchor, constant: 0)
        glyphWidth = glyphView.widthAnchor.constraint(equalToConstant: 0)
        glyphGap = titleLabel.leadingAnchor.constraint(equalTo: glyphView.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            chevronView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            chevronView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevronWidth,
            chevronGap,
            glyphView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            glyphView.heightAnchor.constraint(equalToConstant: 9),
            glyphWidth,
            glyphGap,
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            toggleButton.topAnchor.constraint(equalTo: topAnchor),
            toggleButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        // Full-bleed by default (the whole header toggles). A DRAGGABLE header
        // narrows it to the chevron instead: `NSButton.mouseDown` runs its own
        // tracking loop to mouse-up, so a full-bleed button never lets the
        // outline view see the press and the row cannot start a drag at all.
        toggleFullWidth = toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor)
        toggleChevronWidth = toggleButton.trailingAnchor.constraint(
            equalTo: chevronView.trailingAnchor, constant: 4)
        toggleFullWidth.isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    @objc private func toggleClicked() { onToggle?() }

    func configure(title: String, count: Int,
                   dormant: Int = 0,
                   collapsible: Bool = false,
                   collapsed: Bool = false,
                   accent: NSColor? = nil,
                   symbol: String? = nil,
                   draggable: Bool = false,
                   onToggle: (() -> Void)? = nil) {
        self.onToggle = onToggle
        // A draggable header keeps its click target on the chevron so the rest
        // of the row reaches the outline view and can begin a drag.
        toggleFullWidth.isActive = !draggable
        toggleChevronWidth.isActive = draggable
        toggleButton.isHidden = !collapsible
        chevronView.isHidden = !collapsible
        chevronWidth.constant = collapsible ? 9 : 0
        chevronGap.constant = collapsible ? 3 : 0
        if collapsible {
            let chevronSymbol = collapsed ? "chevron.right" : "chevron.down"
            chevronView.image = NSImage(systemSymbolName: chevronSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
            chevronView.contentTintColor = ZTheme.current.fg3Color
        } else {
            chevronView.image = nil
        }

        let hasGlyph = symbol != nil
        glyphWidth.constant = hasGlyph ? 11 : 0
        glyphGap.constant = hasGlyph ? 4 : 0
        if let symbol, ProjectIcon.isEmoji(symbol) {
            // A Space's glyph is edited through the same IconPicker a
            // project's is (SpaceSheet), which also offers emoji — draw as-is,
            // no template tint, matching ProjectRowView's own emoji branch.
            glyphView.image = ProjectIcon.emojiImage(symbol, pointSize: 9)
            glyphView.contentTintColor = nil
        } else if let symbol {
            glyphView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
            glyphView.contentTintColor = accent ?? ZTheme.current.fg3Color
        } else {
            glyphView.image = nil
        }

        // Uppercase with light letter-spacing (handoff section headers).
        titleLabel.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: ZTheme.chromeFont(size: 10.5, weight: .bold),
                .foregroundColor: ZTheme.current.fg3Color,
                .kern: 1.2,
            ]
        )
        // "3" normally, "3/1" when the section also has dormant members —
        // awake/dormant. Plain digits: a moon glyph next to a number read as
        // decoration rather than a count.
        countLabel.stringValue = dormant > 0 ? "\(count)/\(dormant)" : "\(count)"
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

        // A `bg3` rounded fill and nothing else. The row previously also drew a
        // leading accent bar; it read as a stray sliver against the fill's
        // rounded edge, and the accent already marks focus elsewhere (the status
        // dot, the active tab's top bar), so the fill alone carries selection.
        let fillRect = bounds.insetBy(dx: 4, dy: 1)
        theme.bg3Color.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - ProjectCellView

/// A single project row: name label on the left, pin toggle button on the right.
private final class ProjectCellView: NSTableCellView {

    private let glyphView = NSImageView()
    /// Overlays the glyph slot as a "Cloning…" progress spinner (hidden when stopped).
    private let spinner = NSProgressIndicator()
    private let toolIconView = NSImageView()
    private let nameLabel: NSTextField
    private let pinButton: NSButton
    /// The project's DEFAULT agent account, trailing. Created unconditionally
    /// with a 0↔6 width toggle so the row's constraints never change shape —
    /// these cells are recycled on every refresh.
    private let accountDot = NSView()
    private let accountDotWidth: NSLayoutConstraint
    /// Collapses the tool-logo slot when the project has none (0 width, no gap).
    private var toolIconWidth: NSLayoutConstraint!
    private var toolIconGap: NSLayoutConstraint!
    /// Indents attached clone rows under their source (4pt normal, 18pt cloned).
    private var glyphLeading: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        nameLabel = NSTextField(labelWithString: "")
        pinButton = NSButton(title: "", target: nil, action: nil)
        accountDotWidth = accountDot.widthAnchor.constraint(equalToConstant: 0)

        super.init(frame: frameRect)

        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

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
        accountDot.wantsLayer = true
        accountDot.layer?.cornerRadius = 3
        accountDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accountDot)

        toolIconWidth = toolIconView.widthAnchor.constraint(equalToConstant: 0)
        toolIconGap = nameLabel.leadingAnchor.constraint(equalTo: toolIconView.trailingAnchor, constant: 0)
        glyphLeading = glyphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            glyphLeading,
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: 15),
            glyphView.heightAnchor.constraint(equalToConstant: 15),

            spinner.centerXAnchor.constraint(equalTo: glyphView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: glyphView.centerYAnchor),

            toolIconView.leadingAnchor.constraint(equalTo: glyphView.trailingAnchor, constant: 7),
            toolIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            toolIconWidth,
            toolIconView.heightAnchor.constraint(equalToConstant: 13),

            toolIconGap,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: accountDot.leadingAnchor, constant: -4),
            accountDot.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -4),
            accountDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            accountDot.heightAnchor.constraint(equalToConstant: 6),
            accountDotWidth,

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
                   isClone: Bool = false,
                   isHome: Bool = false,
                   inSpace: Bool = false,
                   spaceName: String? = nil,
                   isPendingClone: Bool = false,
                   accountColor: NSColor? = nil,
                   accountName: String? = nil,
                   projectIndex: Int, target: AnyObject, action: Selector) {
        glyphLeading.constant = isClone ? 18 : 4

        // Re-resolved per render (the palette flips with the scheme), and
        // re-run on every configure because these cells are recycled.
        accountDotWidth.constant = accountColor == nil ? 0 : 6
        accountDot.layer?.backgroundColor = accountColor?.cgColor
        accountDot.toolTip = accountName.map { "New panes here use the \($0) account" }

        // A pending clone is a transient "Cloning…" placeholder: dim label, a
        // progress spinner in place of the glyph, and no tool logo or pin star.
        if isPendingClone {
            nameLabel.stringValue = "Cloning \(name)\u{2026}"
            nameLabel.textColor = ZTheme.current.fg3Color
            glyphView.image = nil
            toolIconView.image = nil
            toolIconWidth.constant = 0
            toolIconGap.constant = 0
            pinButton.isHidden = true
            spinner.startAnimation(nil)
            return
        }
        // Recycled cells may have been a spinner row — stop it.
        spinner.stopAnimation(nil)

        if isHibernated, let spaceName, !spaceName.isEmpty {
            // Hibernated rows all collect under Hibernating, so the row itself
            // has to say which Space it will return to when woken. Attributed
            // text rather than another subview — this cell is recycled on every
            // refresh, and a conditional subview means conditional constraints.
            let text = NSMutableAttributedString(
                string: name,
                attributes: [.foregroundColor: nameLabel.textColor ?? ZTheme.current.fgColor,
                             .font: nameLabel.font ?? ZTheme.chromeFont(size: 12)])
            text.append(NSAttributedString(
                string: "  \(spaceName)",
                attributes: [.foregroundColor: ZTheme.current.fg3Color,
                             .font: ZTheme.chromeFont(size: 10)]))
            nameLabel.attributedStringValue = text
        } else {
            nameLabel.stringValue = name
        }
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
        // Home's default glyph is a house (still overridable by a custom icon).
        let defaultGlyph = isHome ? "house.fill" : ((hasAgent || isActive) ? "diamond.fill" : "diamond")
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

        // Scratch terminals and Home can't be pinned — hide the star entirely.
        // A Space member lives in its Space, not in Pinned, so it has no star —
        // same reasoning as Scratch and Home, which own their own sections.
        pinButton.isHidden = isScratch || isHome || inSpace

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
    /// The pane's agent account, trailing (the leading dot is agent status).
    private let accountDot = NSView()
    private var accountDotWidth: NSLayoutConstraint!

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

        accountDot.wantsLayer = true
        accountDot.layer?.cornerRadius = 3
        accountDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accountDot)

        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 0)
        iconGap = titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 0)
        accountDotWidth = accountDot.widthAnchor.constraint(equalToConstant: 0)
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
            accountDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accountDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            accountDot.heightAnchor.constraint(equalToConstant: 6),
            accountDotWidth,
            titleLabel.trailingAnchor.constraint(equalTo: accountDot.leadingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func configure(title: String, isActive: Bool, agentStatus: AgentStatus?, icon: NSImage? = nil,
                   accountColor: NSColor? = nil) {
        // Trailing, deliberately: the LEADING dot is agent status, and two dots
        // at the same edge would read as one noisy cluster.
        accountDotWidth.constant = accountColor == nil ? 0 : 6
        accountDot.layer?.backgroundColor = accountColor?.cgColor

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
