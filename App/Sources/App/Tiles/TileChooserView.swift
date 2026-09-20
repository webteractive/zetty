import AppKit
import ZettyCore

/// What tile mode shows when no view is open: the layouts you can start from
/// and the profiles you can reopen.
///
/// It is the empty state rather than a separate screen, so the choice lives
/// where the result will appear — and toggling into the grid no longer opens
/// something uninvited.
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
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stack.addArrangedSubview(heading("Start from a layout"))
        stack.addArrangedSubview(row(layouts.enumerated().map { index, layout in
            button(title: layout.name, image: TileConfigSheet.shapeImage(for: layout.root),
                   tag: index, action: #selector(layoutPicked(_:)))
        } + [button(title: "Custom\u{2026}", image: nil, tag: -1,
                    action: #selector(customPicked))]))

        if !profiles.isEmpty {
            stack.addArrangedSubview(heading("Or reopen a view"))
            stack.addArrangedSubview(row(profiles.enumerated().map { index, profile in
                button(title: profile.name,
                       image: TileConfigSheet.shapeImage(for: profile.root),
                       subtitle: "\(profile.attachmentCount) of \(profile.capacity)",
                       tag: index, action: #selector(profilePicked(_:)))
            }))
        }

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
        ])
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = ZTheme.chromeFont(size: 12)
        field.textColor = ZTheme.current.fg2Color
        field.lineBreakMode = .byTruncatingTail
        // Compressible: 750 is inside the band AppKit folds into the window's
        // minimum content size, and this view lives inside the main window.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// Wrapped in a clipping scroll view so a long row of layouts can never
    /// demand width from the window. A stack of fixed-width buttons is REQUIRED
    /// width otherwise — eight of them is ~780pt nobody bounded, and the
    /// sidebar (whose own width is deliberately `.defaultLow`) then absorbs
    /// whatever is left over.
    private func row(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.documentView = row
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 76),
        ])
        // The clip is sized by the OUTER chain only — never by the strip inside
        // it. Same rule the tab strip documents at length.
        let width = scroll.widthAnchor.constraint(equalToConstant: 900)
        width.priority = .defaultLow
        width.isActive = true
        return scroll
    }

    private func button(title: String, image: NSImage?, subtitle: String? = nil,
                        tag: Int, action: Selector) -> NSButton {
        let button = NSButton(title: subtitle.map { "\(title)\n\($0)" } ?? title,
                              target: self, action: action)
        button.tag = tag
        button.bezelStyle = .smallSquare
        button.imagePosition = image == nil ? .noImage : .imageAbove
        button.image = image
        button.font = ZTheme.chromeFont(size: 11)
        button.contentTintColor = ZTheme.current.fg2Color
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 82),
            button.heightAnchor.constraint(equalToConstant: 72),
        ])
        return button
    }

    @objc private func layoutPicked(_ sender: NSButton) {
        guard layouts.indices.contains(sender.tag) else { return }
        onPickLayout(layouts[sender.tag])
    }

    @objc private func profilePicked(_ sender: NSButton) {
        guard profiles.indices.contains(sender.tag) else { return }
        onPickProfile(profiles[sender.tag])
    }

    @objc private func customPicked() { onCustom() }
}
