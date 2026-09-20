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

    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private var tiles: [TileView] = []
    private let onActivate: (UUID) -> Void
    private let onGoToPane: (UUID) -> Void
    /// A hole or a missing slot was clicked — open the picker for that index.
    private let onAttach: (Int) -> Void
    /// Remove that slot from the view. The pane keeps running.
    private let onDetach: (Int) -> Void
    /// A sidebar tab row was dropped on a slot: "project:tab" indices, and the
    /// slot it landed in. Returns whether it was accepted.
    var onDropSidebarTab: ((Int, Int, Int) -> Bool)?
    private var focusedID: UUID?

    /// Supplies `zetty-tiles-grid` at layout time rather than at construction,
    /// so ⇧⌘, reload reaches an open grid without rebuilding it.
    private let gridProvider: () -> TilesGrid
    /// Reports the running/idle split to whoever renders it — the status bar.
    private let onCounts: (Int, Int) -> Void

    init(gridProvider: @escaping () -> TilesGrid,
         onCounts: @escaping (Int, Int) -> Void,
         onActivate: @escaping (UUID) -> Void,
         onGoToPane: @escaping (UUID) -> Void,
         onAttach: @escaping (Int) -> Void,
         onDetach: @escaping (Int) -> Void) {
        self.gridProvider = gridProvider
        self.onCounts = onCounts
        self.onActivate = onActivate
        self.onGoToPane = onGoToPane
        self.onAttach = onAttach
        self.onDetach = onDetach
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

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.documentView = documentView
        addSubview(scrollView)

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
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
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
            scrollView.isHidden = true
            onCounts(0, 0)
            return
        }
        // Cleared, not just hidden: an unset string keeps its intrinsic width.
        emptyLabel.stringValue = ""
        emptyLabel.isHidden = true
        scrollView.isHidden = false

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
                // A hole or a missing slot activates the picker; a live tile
                // takes focus. Reattach on a missing tile lands here too.
                onActivate: { [weak self] in
                    guard let id else { self?.onAttach(index); return }
                    self?.onActivate(id)
                },
                onGoToPane: { [weak self] in if let id { self?.onGoToPane(id) } },
                onDetach: { [weak self] in self?.onDetach(index) })
            tile.translatesAutoresizingMaskIntoConstraints = true
            documentView.addSubview(tile)
            tiles.append(tile)
        }
        needsLayout = true
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
        let local = documentView.convert(windowPoint, from: nil)
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

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard !tiles.isEmpty else {
            documentView.frame = .zero
            return
        }
        let clip = scrollView.contentView.bounds.size
        let available = CGSize(width: clip.width - Self.inset * 2,
                               height: clip.height - Self.inset * 2)
        guard available.width > 0, available.height > 0 else { return }

        let grid = TileGrid.layout(count: tiles.count,
                                   width: Double(available.width),
                                   height: Double(available.height),
                                   grid: gridProvider())
        guard grid.columns > 0 else { return }

        let spacing = CGFloat(TileGrid.spacing)
        let tileW = CGFloat(grid.tileWidth)
        let tileH = CGFloat(grid.tileHeight)
        let documentHeight = CGFloat(grid.rows) * tileH
            + CGFloat(max(0, grid.rows - 1)) * spacing
            + Self.inset * 2
        documentView.frame = NSRect(x: 0, y: 0,
                                    width: clip.width,
                                    height: max(clip.height, documentHeight))

        for (index, tile) in tiles.enumerated() {
            let column = index % grid.columns
            let row = index / grid.columns
            let x = Self.inset + CGFloat(column) * (tileW + spacing)
            // The document view is unflipped, so y grows upward: row 0 must
            // sit at the TOP of the document.
            let y = documentView.frame.height - Self.inset - tileH
                - CGFloat(row) * (tileH + spacing)
            tile.frame = NSRect(x: x, y: y, width: tileW, height: tileH)
        }

        let configured = gridProvider()
        ZettyLog.chrome.log("tiles: count=\(tiles.count) cols=\(grid.columns) "
            + "cap=\(configured.configValue) "
            + "rows=\(grid.rows) tile=\(Int(tileW))x\(Int(tileH)) "
            + "scrolls=\(grid.scrolls) clip=\(Int(clip.width))x\(Int(clip.height))")
    }
}
