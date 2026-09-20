import AppKit
import ZettyCore

// MARK: - Card

/// One choosable thing in the chooser: a shape, a name, and an optional
/// subtitle, centred in a rounded well.
///
/// A hand-built view rather than an `NSButton` with `.imageAbove` — that style
/// centres neither the image nor the title reliably, and there is no way to
/// give the two different fonts or colours.
@MainActor
private final class TileChooserCard: NSView {

    static let size = NSSize(width: 104, height: 96)

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let onPick: () -> Void
    private var isHovering = false

    init(image: NSImage?, title: String, subtitle: String?, onPick: @escaping () -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        iconView.image = image
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.alignment = .center
        titleLabel.font = ZTheme.chromeFont(size: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.alignment = .center
        subtitleLabel.font = ZTheme.chromeFont(size: 10)
        subtitleLabel.isHidden = subtitle == nil
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        // The icon is centred in the space ABOVE the text block rather than
        // stacked with it, so a card with a subtitle and one without still put
        // their shapes on the same line.
        // Below `.defaultLow`, so a narrow window compresses the cards rather
        // than being unable to shrink. Nothing else competes for this width, so
        // at any normal size they are simply their full size.
        let cardWidth = widthAnchor.constraint(equalToConstant: Self.size.width)
        cardWidth.priority = .init(249)
        NSLayoutConstraint.activate([
            cardWidth,
            heightAnchor.constraint(equalToConstant: Self.size.height),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                 constant: -6),

            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                   constant: 6),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                    constant: -6),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

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

// MARK: - TileChooserView

/// What tile mode shows when no view is open: the layouts you can start from
/// and the views you can reopen.
///
/// It is the empty state rather than a separate screen, so the choice lives
/// where the result will appear.
@MainActor
final class TileChooserView: NSView {

    private let layouts: [TileLayout]
    private let profiles: [TileProfile]
    private let onPickLayout: (TileLayout) -> Void
    private let onPickProfile: (TileProfile) -> Void
    private let onCustom: () -> Void

    private let stack = NSStackView()

    init(layouts: [TileLayout],
         profiles: [TileProfile],
         onPickLayout: @escaping (TileLayout) -> Void,
         onPickProfile: @escaping (TileProfile) -> Void,
         onCustom: @escaping () -> Void) {
        self.layouts = layouts
        self.profiles = profiles
        self.onPickLayout = onPickLayout
        self.onPickProfile = onPickProfile
        self.onCustom = onCustom
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = ZTheme.current.bg1Color.cgColor
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stack.addArrangedSubview(heading("Start from a layout"))
        var cards: [NSView] = layouts.map { layout in
            TileChooserCard(image: TileConfigSheet.shapeImage(for: layout.root, size: 36),
                            title: layout.name, subtitle: nil) { [weak self] in
                self?.onPickLayout(layout)
            }
        }
        cards.append(TileChooserCard(image: nil, title: "Custom\u{2026}",
                                     subtitle: nil) { [weak self] in self?.onCustom() })
        stack.addArrangedSubview(row(cards))

        if !profiles.isEmpty {
            let reopen = heading("Or reopen a view")
            stack.setCustomSpacing(22, after: stack.arrangedSubviews.last ?? reopen)
            stack.addArrangedSubview(reopen)
            stack.addArrangedSubview(row(profiles.map { profile in
                TileChooserCard(
                    image: TileConfigSheet.shapeImage(for: profile.root, size: 36),
                    title: profile.name,
                    subtitle: "\(profile.attachmentCount) of \(profile.capacity)"
                ) { [weak self] in self?.onPickProfile(profile) }
            }))
        }

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .center
        field.font = ZTheme.chromeFont(size: 12)
        field.textColor = ZTheme.current.fg2Color
        field.lineBreakMode = .byTruncatingTail
        // 750 is inside the band AppKit folds into the window's minimum content
        // size, and this view lives inside the main window.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// A plain centred row.
    ///
    /// No wrapping, no scroll view, no measuring: an earlier version computed
    /// its own layout from its laid-out width, which is circular — before the
    /// first pass that width is zero, and it rendered every card in a single
    /// column. A stack centred by its parent cannot get that wrong.
    private func row(_ cards: [NSView]) -> NSView {
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.spacing = 12
        row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }
}
