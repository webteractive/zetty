import AppKit
import ZettyCore

// MARK: - Card

/// One choosable thing in the chooser: a shape, a name, and an optional
/// subtitle, centred in a rounded well.
///
/// A hand-built view rather than an `NSButton` with `.imageAbove` — that style
/// centres neither the image nor the title reliably, and there is no way to
/// give the two different fonts or colours.
///
/// The card carries NO size constraints of its own: the chooser sets every
/// card's frame, so all cards are identical by construction instead of by a
/// priority contest their labels kept winning.
@MainActor
private final class TileChooserCard: NSView {

    static let size = NSSize(width: 120, height: 120)
    static let iconSize: CGFloat = 44

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let onPick: () -> Void
    private var isHovering = false

    init(image: NSImage?, title: String, subtitle: String?, onPick: @escaping () -> Void) {
        self.onPick = onPick
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        iconView.image = image
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        for (label, size, text) in [(titleLabel, CGFloat(11), title),
                                    (subtitleLabel, CGFloat(10), subtitle ?? "")] {
            label.stringValue = text
            label.alignment = .center
            label.font = ZTheme.chromeFont(size: size)
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }
        subtitleLabel.isHidden = subtitle == nil
        applyTheme()
        // The parent hands out a frame the same size as the one above, so a
        // size change can't be relied on to trigger the first pass.
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Frame layout throughout: the icon sits on a fixed line so a card with a
    /// subtitle and one without still put their shapes at the same height.
    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let width = bounds.width - inset * 2
        let icon = min(Self.iconSize, max(0, width))
        iconView.frame = NSRect(x: (bounds.width - icon).rounded() / 2,
                                y: bounds.height - 20 - icon,
                                width: icon, height: icon)

        let titleHeight = ceil(titleLabel.font?.boundingRectForFont.height ?? 14)
        let subtitleHeight = subtitleLabel.isHidden
            ? 0
            : ceil(subtitleLabel.font?.boundingRectForFont.height ?? 12)
        var y = iconView.frame.minY - 12 - titleHeight
        titleLabel.frame = NSRect(x: inset, y: y, width: max(0, width), height: titleHeight)
        y -= 2 + subtitleHeight
        subtitleLabel.frame = NSRect(x: inset, y: y,
                                     width: max(0, width), height: subtitleHeight)
    }

    private func applyTheme() {
        let theme = ZTheme.current
        // Elevated surface for a control, accent only on hover — the ramp the
        // design rules set out.
        layer?.backgroundColor = (isHovering ? theme.bg3Color : theme.bg2Color).cgColor
        layer?.borderColor = (isHovering ? theme.accentColor : theme.borderColor).cgColor
        iconView.contentTintColor = isHovering ? theme.accentColor : theme.fg2Color
        titleLabel.textColor = theme.fgColor
        subtitleLabel.textColor = theme.fg3Color
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyTheme()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyTheme()
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick()
    }
}

// MARK: - Content

@MainActor
private struct ChooserSection {
    let heading: NSTextField
    let cards: [NSView]
}

/// The scroll view's document view: headings and wrapped rows of cards, laid
/// out top-down and flush left.
///
/// Frame layout, deliberately — and it is not the circular version an earlier
/// attempt shipped. Nothing here measures a laid-out *subview*: the card size
/// is a constant and the only input is this view's own width, which follows
/// the clip view through `autoresizingMask`.
///
/// Constraints are the wrong tool twice over. A required card width would
/// become a window minimum (this view lives in the main window, the trap
/// documented at length for the tab strip and the command palette), and a
/// low-priority one loses to a stack view's own hugging — which is exactly how
/// the cards ended up sized by their labels, one ballooning to fill the
/// leftover space.
@MainActor
private final class TileChooserContentView: NSView {

    static let gap: CGFloat = 12
    static let margin: CGFloat = 24
    static let headingGap: CGFloat = 12
    static let sectionGap: CGFloat = 28

    var sections: [ChooserSection] = []

    /// Top-down, so a list longer than the window grows off the bottom rather
    /// than off the top.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let available = max(0, bounds.width - Self.margin * 2)
        let cardWidth = min(TileChooserCard.size.width, available)
        let cardHeight = TileChooserCard.size.height
        let perRow = max(1, Int((available + Self.gap) / (cardWidth + Self.gap)))

        var y = Self.margin
        for (index, section) in sections.enumerated() {
            let headingSize = headingHeight(section.heading)
            section.heading.frame = NSRect(x: Self.margin, y: y,
                                           width: available, height: headingSize)
            y += headingSize + Self.headingGap

            let rows = Int(ceil(Double(section.cards.count) / Double(perRow)))
            for row in 0..<rows {
                let slice = Array(section.cards.dropFirst(row * perRow).prefix(perRow))
                var x = Self.margin
                for card in slice {
                    card.frame = NSRect(x: x, y: y, width: cardWidth, height: cardHeight)
                    card.needsLayout = true
                    x += cardWidth + Self.gap
                }
                y += cardHeight + Self.gap
            }
            if rows > 0 { y -= Self.gap }
            y += index < sections.count - 1 ? Self.sectionGap : Self.margin
        }

        // The document view's height IS the content height; the clip view
        // scrolls whatever exceeds it. Guarded, or setting it here would
        // re-enter layout forever.
        if abs(frame.height - y) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: y))
        }
    }

    private func headingHeight(_ field: NSTextField) -> CGFloat {
        ceil(field.font?.boundingRectForFont.height ?? 16)
    }
}

// MARK: - TileChooserView

/// What tile mode shows when no view is open: the layouts you can start from
/// and the views you can reopen.
///
/// It is the empty state rather than a separate screen, so the choice lives
/// where the result will appear.
@MainActor
final class TileChooserView: NSView {

    private let scrollView = NSScrollView()
    private let content = TileChooserContentView()

    private let onPickLayout: (TileLayout) -> Void
    private let onPickProfile: (TileProfile) -> Void
    private let onCustom: () -> Void

    init(layouts: [TileLayout],
         profiles: [TileProfile],
         onPickLayout: @escaping (TileLayout) -> Void,
         onPickProfile: @escaping (TileProfile) -> Void,
         onCustom: @escaping () -> Void) {
        self.onPickLayout = onPickLayout
        self.onPickProfile = onPickProfile
        self.onCustom = onCustom
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = ZTheme.current.bg1Color.cgColor

        content.autoresizingMask = [.width]
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = content
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        var starters: [NSView] = layouts.map { layout in
            card(for: layout.root, title: layout.name, subtitle: nil) { [weak self] in
                self?.onPickLayout(layout)
            }
        }
        starters.append(TileChooserCard(image: nil, title: "Custom\u{2026}", subtitle: nil) {
            [weak self] in self?.onCustom()
        })
        add(ChooserSection(heading: heading("Start from layout"), cards: starters))

        if !profiles.isEmpty {
            let reopen = profiles.map { profile in
                card(for: profile.root,
                     title: profile.name,
                     subtitle: "\(profile.attachmentCount) of \(profile.capacity)") {
                    [weak self] in self?.onPickProfile(profile)
                }
            }
            add(ChooserSection(heading: heading("Or reopen view"), cards: reopen))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The document view's width is set here rather than left to autoresizing:
    /// it starts at zero, and a zero width autoresizes to zero forever.
    override func layout() {
        super.layout()
        let width = scrollView.contentSize.width
        if abs(content.frame.width - width) > 0.5 {
            content.setFrameSize(NSSize(width: width, height: content.frame.height))
            content.needsLayout = true
        }
    }

    // MARK: - Building

    private func add(_ section: ChooserSection) {
        content.sections.append(section)
        content.addSubview(section.heading)
        section.cards.forEach(content.addSubview)
        content.needsLayout = true
    }

    private func card(for root: TileNode,
                      title: String,
                      subtitle: String?,
                      onPick: @escaping () -> Void) -> TileChooserCard {
        TileChooserCard(image: TileConfigSheet.shapeImage(for: root,
                                                          size: TileChooserCard.iconSize),
                        title: title,
                        subtitle: subtitle,
                        onPick: onPick)
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .left
        field.font = ZTheme.chromeFont(size: 12)
        field.textColor = ZTheme.current.fg2Color
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        return field
    }
}
