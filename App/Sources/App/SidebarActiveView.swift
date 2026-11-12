import AppKit
import ZettyCore

/// The sidebar's Active section: every agent session working or needing you,
/// on this Mac and the other Macs shown. A fixed area between the filter field
/// and the scrolling project list, so it stays in view however far the list
/// scrolls, and rows coming and going never shift the rows below it. Absent
/// (zero height) while nothing is busy. Collapsible from its header like the
/// outline's sections (transient, like them); collapsed keeps the header and
/// count. Rows are shortcuts: no drag, no menu. What it lists and in what
/// order is `ActiveSessions`.
@MainActor
final class SidebarActiveView: NSView {

    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 26
    /// The area grows with its rows up to this many, then scrolls inside itself.
    static let maxVisibleRows = 5

    var onSelect: ((ActiveSession.Target) -> Void)?
    /// The header was clicked; the owner flips `isCollapsed`.
    var onToggleCollapsed: (() -> Void)?
    var isCollapsed = false {
        didSet { if oldValue != isCollapsed { applyLayout() } }
    }

    private let chevronView = NSImageView()
    /// Full-bleed over the header, like the outline headers' toggle.
    private let toggleButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let list = NSStackView()
    private var heightConstraint: NSLayoutConstraint!
    private var rowViews: [String: ActiveRowView] = [:]
    private var rows: [ActiveRow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true

        for label in [titleLabel, countLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        countLabel.alignment = .right
        chevronView.imageScaling = .scaleProportionallyDown
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronView)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = ActiveFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        toggleButton.title = ""
        toggleButton.isBordered = false
        toggleButton.setButtonType(.momentaryChange)
        toggleButton.focusRingType = .none
        toggleButton.target = self
        toggleButton.action = #selector(toggleClicked)
        toggleButton.setAccessibilityLabel("Active")
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggleButton)   // topmost over the header — captures clicks, draws nothing

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            // Same insets as the outline's collapsible section headers below
            // it: chevron where their chevrons sit, title after it.
            chevronView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 29),
            chevronView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: chevronView.trailingAnchor, constant: 3),
            titleLabel.bottomAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight - 3),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            toggleButton.topAnchor.constraint(equalTo: topAnchor),
            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggleButton.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            // Inset like the outline's selection fill, so hover reads the same.
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        applyTheme()
        applyLayout()   // empty: hidden, zero height
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    @objc private func toggleClicked() { onToggleCollapsed?() }

    /// Shows `rows` (already filtered), re-rendering in place: a row keeps its
    /// view across refreshes, and the list is re-ordered only when the order
    /// changed. Agents flip status many times a minute.
    func update(rows newRows: [ActiveRow]) {
        guard newRows != rows else { return }
        let orderChanged = newRows.map(\.id) != rows.map(\.id)
        rows = newRows

        let ids = Set(newRows.map(\.id))
        for (id, view) in rowViews where !ids.contains(id) {
            view.removeFromSuperview()
            rowViews[id] = nil
        }
        for row in newRows {
            let view = rowViews[row.id] ?? {
                let made = ActiveRowView()
                made.onClick = { [weak self] target in self?.onSelect?(target) }
                rowViews[row.id] = made
                return made
            }()
            view.configure(row)
        }
        if orderChanged {
            list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
            for row in newRows {
                guard let view = rowViews[row.id] else { continue }
                list.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }

        countLabel.stringValue = "\(newRows.count)"
        applyLayout()
    }

    /// Height, visibility and chevron for the current rows and collapse state.
    private func applyLayout() {
        let visible = isCollapsed ? 0 : min(rows.count, Self.maxVisibleRows)
        heightConstraint.constant = rows.isEmpty
            ? 0 : Self.headerHeight + CGFloat(visible) * Self.rowHeight + (isCollapsed ? 0 : 4)
        scrollView.isHidden = isCollapsed
        isHidden = rows.isEmpty
        chevronView.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
                                    accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        toggleButton.setAccessibilityValue(isCollapsed ? "collapsed" : "expanded")
    }

    func applyTheme() {
        let theme = ZTheme.current
        // Uppercase with light letter-spacing, like the outline's headers.
        titleLabel.attributedStringValue = NSAttributedString(
            string: "ACTIVE",
            attributes: [.font: ZTheme.chromeFont(size: 10.5, weight: .bold),
                         .foregroundColor: theme.fg3Color, .kern: 1.2])
        countLabel.font = ZTheme.chromeFont(size: 10.5)
        countLabel.textColor = theme.fg3Color
        chevronView.contentTintColor = theme.fg3Color
        for view in rowViews.values { view.applyTheme() }
    }
}

private final class ActiveFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One Active row: status dot (yellow needs you, green working), the tool's
/// logo, then "project · Tool". Hover fills `bg2`, like other sidebar rows.
private final class ActiveRowView: NSView {

    var onClick: ((ActiveSession.Target) -> Void)?

    private let dot = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint!
    private var iconGap: NSLayoutConstraint!
    private var row: ActiveRow?
    private var hovering = false { didSet { updateBackground() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(dot)
        addSubview(iconView)
        addSubview(label)

        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 0)
        iconGap = label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SidebarActiveView.rowHeight),
            // The dot centres under the project glyphs below, the text lines
            // up with their names.
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 29),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            iconView.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.heightAnchor.constraint(equalToConstant: 13),
            iconWidth,
            iconGap,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func configure(_ row: ActiveRow) {
        guard row != self.row else { return }
        self.row = row
        let icon = row.tool.flatMap(AgentIcons.icon(for:))
        iconView.image = icon
        iconWidth.constant = icon == nil ? 0 : 13
        iconGap.constant = icon == nil ? 4 : 6
        label.stringValue = row.label
        toolTip = row.label
        setAccessibilityLabel(row.label)
        applyTheme()
    }

    func applyTheme() {
        let theme = ZTheme.current
        dot.layer?.backgroundColor = (row.flatMap { agentStatusColor($0.status) } ?? theme.fg3Color).cgColor
        label.font = ZTheme.chromeFont(size: 12)
        label.textColor = theme.fg2Color
        iconView.contentTintColor = theme.fg2Color
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = hovering ? ZTheme.current.bg2Color.cgColor : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        if let row { onClick?(row.target) }
    }
    override func accessibilityPerformPress() -> Bool {
        if let row { onClick?(row.target) }
        return row != nil
    }
}
