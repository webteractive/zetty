import AppKit
import ZettyCore

// MARK: - TileDescriptor

/// Everything the grid needs to render one tile.
struct TileDescriptor {
    /// Position in the profile, which is what attach and detach address —
    /// a hole has no surface, so the slot index is the only stable handle.
    let slotIndex: Int
    let surfaceID: UUID?
    let label: String
    let icon: NSImage?
    let status: TileStatus
    let content: TileContent
    /// Whether a split exists to collapse. `TileNode.close` refuses the last
    /// leaf, so without this the controls would offer a no-op in the one view
    /// where it is most likely to be tried — a fresh single-slot Freeform.
    let canRemove: Bool
    /// Whether this pane's agent can be restarted on its existing
    /// conversation — exactly "a resume line can be built".
    let canRefresh: Bool
}

// MARK: - TileGridView

/// The tile grid: a scrollable field of tiles laid out by `TileGrid`.
///
/// It has no header of its own. The running/idle count lives in the status
/// bar's left cluster instead, because a strip above the grid spent 28pt of
/// height on one line of text that the status bar was already there to carry.
///
/// Tiles are frame-positioned inside the document view rather than
/// Auto-Layout'd against it. That is deliberate and mirrors the tab strip's
/// `+` button: nothing here may constrain the clip's size to its content, or
/// the grid's intrinsic size becomes a window minimum. See the tab-strip note
/// in CLAUDE.md — this window's 320pt floor has been broken three times that
/// way.
@MainActor
final class TileGridView: NSView {

    /// Matches `TileGrid.spacing`, so the outer margin reads as the same gap
    /// as the ones between tiles.
    private static let inset = CGFloat(TileGrid.spacing)

    private let emptyLabel = NSTextField(labelWithString: "")

    private var tiles: [TileView] = []
    private let onActivate: (UUID) -> Void
    private let onGoToPane: (UUID) -> Void
    /// Open that pane's own working directory. Per tile, never the focused
    /// one — that distinction is the point of moving it off the status bar.
    private let onOpen: (UUID, NSView) -> Void
    /// Restart that pane's agent on its existing conversation.
    private let onRefresh: (UUID) -> Void
    /// A hole or a missing slot was clicked — open the picker for that index.
    private let onAttach: (Int) -> Void
    /// Remove that slot from the view. The pane keeps running.
    private let onDetach: (Int) -> Void
    /// Divide that slot in two.
    private let onSplit: (Int, SplitDirection) -> Void
    /// A sidebar tab row was dropped on a slot: "project:tab" indices, and the
    /// slot it landed in. Returns whether it was accepted.
    var onDropSidebarTab: ((Int, Int, Int) -> Bool)?
    /// A divider moved: its index (as `TileNode.dividers` numbers them), the
    /// new ratio, and whether the gesture has ended. Only the final call
    /// persists — see `mutateActiveTileProfile(persist:)`.
    var onSetRatio: ((Int, Double, Bool) -> Void)?

    /// Retunes each tile's refresh button without rebuilding the grid.
    ///
    /// Tiles are recreated only on structural changes, but an agent starts and
    /// stops between them — so without this the button appears only after an
    /// unrelated change, which is the same staleness the pane gutter has to
    /// avoid.
    func updateRefreshButtons(_ canRefresh: (UUID) -> Bool) {
        for tile in tiles {
            guard let id = tile.surfaceID else { continue }
            tile.setRefreshVisible(canRefresh(id))
        }
    }

    private var dividerViews: [TileDividerView] = []
    private var focusedID: UUID?

    /// The active profile's layout tree, read at layout time rather than at
    /// construction so an edit reaches an open grid without rebuilding it.
    private let rootProvider: () -> TileNode
    /// Reports the running/idle split to whoever renders it — the status bar.
    private let onCounts: (Int, Int) -> Void

    init(rootProvider: @escaping () -> TileNode,
         onCounts: @escaping (Int, Int) -> Void,
         onActivate: @escaping (UUID) -> Void,
         onGoToPane: @escaping (UUID) -> Void,
         onOpen: @escaping (UUID, NSView) -> Void,
         onRefresh: @escaping (UUID) -> Void,
         onAttach: @escaping (Int) -> Void,
         onDetach: @escaping (Int) -> Void,
         onSplit: @escaping (Int, SplitDirection) -> Void) {
        self.rootProvider = rootProvider
        self.onCounts = onCounts
        self.onActivate = onActivate
        self.onGoToPane = onGoToPane
        self.onOpen = onOpen
        self.onRefresh = onRefresh
        self.onAttach = onAttach
        self.onDetach = onDetach
        self.onSplit = onSplit
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The sidebar's own tab-row type — dropping onto the GRID, which is
        // outside the outline view, so `validateDrop`'s refuse-everything rule
        // (the thing protecting the pinned-first invariant) is not involved.
        registerForDraggedTypes([SidebarView.tabDragType])
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let theme = ZTheme.current
        layer?.backgroundColor = theme.bg1Color.cgColor

        emptyLabel.font = ZTheme.chromeFont(size: 12)
        emptyLabel.textColor = theme.fg3Color
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 3
        // 750 is inside the band AppKit folds into the window's minimum content
        // size, and a HIDDEN view still participates in layout — so a long
        // empty-state string would hold the window open even once tiles appear.
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                 constant: -16),
        ])
    }

    // MARK: - Content

    func update(tiles descriptors: [TileDescriptor], focused: UUID?,
                emptyMessage: String?) {
        focusedID = focused

        for tile in tiles { tile.removeFromSuperview() }
        tiles = []

        if let message = emptyMessage {
            emptyLabel.stringValue = message
            emptyLabel.isHidden = false
            onCounts(0, 0)
            return
        }
        // Cleared, not just hidden: an unset string keeps its intrinsic width.
        emptyLabel.stringValue = ""
        emptyLabel.isHidden = true

        let attached = descriptors.filter { $0.surfaceID != nil }
        let running = attached.filter { $0.status != .idle }.count
        onCounts(running, attached.count - running)

        for descriptor in descriptors {
            let id = descriptor.surfaceID
            let index = descriptor.slotIndex
            let tile = TileView(
                surfaceID: id,
                slotIndex: index,
                label: descriptor.label,
                icon: descriptor.icon,
                status: descriptor.status,
                isFocused: id != nil && id == focused,
                content: descriptor.content,
                canRemove: descriptor.canRemove,
                canRefresh: descriptor.canRefresh,
                // A hole or a missing slot activates the picker; a live tile
                // takes focus. Reattach on a missing tile lands here too.
                onActivate: { [weak self] in
                    guard let id else { self?.onAttach(index); return }
                    self?.onActivate(id)
                },
                onGoToPane: { [weak self] in if let id { self?.onGoToPane(id) } },
                onOpen: { [weak self] anchor in if let id { self?.onOpen(id, anchor) } },
                onRefresh: { [weak self] in if let id { self?.onRefresh(id) } },
                onDetach: { [weak self] in self?.onDetach(index) },
                onSplit: { [weak self] direction in self?.onSplit(index, direction) })
            tile.translatesAutoresizingMaskIntoConstraints = true
            addSubview(tile)
            tiles.append(tile)
        }
        needsLayout = true
    }

    /// Restyle everything this view owns for the CURRENT scheme.
    ///
    /// The corollary the chrome-refresh rules set out: `rebuildSurfaceNodeView`
    /// reuses this grid across a scheme change (it removes it from the
    /// container but keeps the instance), so colours set once in `build()` —
    /// the background and the empty label — would freeze in the old palette.
    /// The tiles are restyled too rather than relying on the rebuild that
    /// recreates them, so this is correct on its own.
    func applyTheme() {
        let theme = ZTheme.current
        layer?.backgroundColor = theme.bg1Color.cgColor
        emptyLabel.font = ZTheme.chromeFont(size: 12)
        emptyLabel.textColor = theme.fg3Color
        for tile in tiles { tile.applyTheme() }
    }

    var focusedTileView: TileView? {
        tiles.first { $0.surfaceID == focusedID }
    }

    func setFocused(_ id: UUID?) {
        focusedID = id
        for tile in tiles { tile.setFocused(tile.surfaceID == id) }
    }

    // MARK: - Drop target

    /// Which slot a point falls in, from the geometry the last layout pass
    /// produced. Reading the frames rather than recomputing the arithmetic is
    /// what stops the drop target drifting away from what is drawn.
    private func slotIndex(at windowPoint: NSPoint) -> Int? {
        let local = convert(windowPoint, from: nil)
        return tiles.firstIndex { $0.frame.contains(local) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: SidebarView.tabDragType) != nil
            ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = sender.draggingPasteboard.string(forType: SidebarView.tabDragType)
        else { return false }
        let parts = payload.split(separator: ":")
        guard parts.count == 2,
              let project = Int(parts[0]), let tab = Int(parts[1]),
              // Past the last tile appends, which is what dropping into the
              // empty area below the grid should mean.
              let slot = slotIndex(at: sender.draggingLocation) ?? tiles.indices.last.map({ $0 + 1 })
        else { return false }
        return onDropSidebarTab?(project, tab, slot) ?? false
    }

    // MARK: - Dividers

    /// One draggable handle per split, placed on the boundary between its two
    /// subtrees. Rebuilt per pass because the tree can change under us; they
    /// are cheap, frame-positioned views with no constraints.
    private func layoutDividers(root: TileNode, area: NSRect) {
        let dividers = root.dividers(in: LayoutRect(x: 0, y: 0, width: 1, height: 1))
        while dividerViews.count > dividers.count {
            dividerViews.removeLast().removeFromSuperview()
        }
        while dividerViews.count < dividers.count {
            let view = TileDividerView()
            view.onDrag = { [weak self] index, ratio, isFinal in
                self?.onSetRatio?(index, ratio, isFinal)
            }
            addSubview(view)
            dividerViews.append(view)
        }

        let thickness: CGFloat = CGFloat(TileGrid.spacing)
        for (view, divider) in zip(dividerViews, dividers) {
            let rect = NSRect(
                x: area.minX + CGFloat(divider.rect.x) * area.width,
                y: area.minY + area.height
                    - CGFloat(divider.rect.y + divider.rect.height) * area.height,
                width: CGFloat(divider.rect.width) * area.width,
                height: CGFloat(divider.rect.height) * area.height)
            view.configure(index: divider.index, direction: divider.direction,
                           splitRect: rect)
            switch divider.direction {
            case .vertical:
                let x = rect.minX + rect.width * CGFloat(divider.ratio)
                view.frame = NSRect(x: x - thickness / 2, y: rect.minY,
                                    width: thickness, height: rect.height)
            case .horizontal:
                // The rect is top-left-origin; this view is not.
                let y = rect.maxY - rect.height * CGFloat(divider.ratio)
                view.frame = NSRect(x: rect.minX, y: y - thickness / 2,
                                    width: rect.width, height: thickness)
            }
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard !tiles.isEmpty else { return }
        let inset = Self.inset
        let area = NSRect(x: inset, y: inset,
                          width: bounds.width - inset * 2,
                          height: bounds.height - inset * 2)
        guard area.width > 0, area.height > 0 else { return }

        let root = rootProvider()
        let gap = CGFloat(TileGrid.spacing) / 2
        let frames = root.frames(in: LayoutRect(x: 0, y: 0, width: 1, height: 1))

        for (index, tile) in tiles.enumerated() {
            guard index < frames.count else { tile.frame = .zero; continue }
            let frame = frames[index]
            // LayoutRect is top-left-origin; an unflipped NSView is not.
            tile.frame = NSRect(
                x: area.minX + CGFloat(frame.x) * area.width + gap,
                y: area.minY + area.height
                    - CGFloat(frame.y + frame.height) * area.height + gap,
                width: CGFloat(frame.width) * area.width - gap * 2,
                height: CGFloat(frame.height) * area.height - gap * 2)
        }

        layoutDividers(root: root, area: area)

        ZettyLog.chrome.log("tiles: leaves=\(frames.count) depth=\(root.depth) "
            + "bounds=\(Int(bounds.width))x\(Int(bounds.height))")
    }
}
