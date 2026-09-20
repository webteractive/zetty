import AppKit
import ZettyCore

// MARK: - TileDescriptor

/// Everything the grid needs to render one tile.
struct TileDescriptor {
    let surfaceID: UUID
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
    private var focusedID: UUID?

    /// Supplies `zetty-tiles-grid` at layout time rather than at construction,
    /// so ⇧⌘, reload reaches an open grid without rebuilding it.
    private let gridProvider: () -> TilesGrid
    /// Reports the running/idle split to whoever renders it — the status bar.
    private let onCounts: (Int, Int) -> Void

    init(gridProvider: @escaping () -> TilesGrid,
         onCounts: @escaping (Int, Int) -> Void,
         onActivate: @escaping (UUID) -> Void,
         onGoToPane: @escaping (UUID) -> Void) {
        self.gridProvider = gridProvider
        self.onCounts = onCounts
        self.onActivate = onActivate
        self.onGoToPane = onGoToPane
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
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
        emptyLabel.isHidden = true
        scrollView.isHidden = false

        let running = descriptors.filter { $0.status != .idle }.count
        onCounts(running, descriptors.count - running)

        for descriptor in descriptors {
            let id = descriptor.surfaceID
            let tile = TileView(
                surfaceID: id,
                label: descriptor.label,
                icon: descriptor.icon,
                status: descriptor.status,
                isFocused: id == focused,
                content: descriptor.content,
                onActivate: { [weak self] in self?.onActivate(id) },
                onGoToPane: { [weak self] in self?.onGoToPane(id) })
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
