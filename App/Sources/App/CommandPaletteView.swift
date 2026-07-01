import AppKit

// MARK: - PaletteCommand

/// One runnable entry in the command palette.
struct PaletteCommand {
    let glyph: String       // single-char icon shown in the chip
    let label: String
    let kbd: String         // display-only shortcut hint (may be empty)
    let run: () -> Void
}

// MARK: - CommandPaletteView

/// A ⌘K-style command palette: a scrim + centered panel with a search field,
/// a filterable command list, and keyboard navigation (↑↓ move, ↵ run, esc
/// close). Self-contained — created with a command list and an `onClose`
/// closure; it fills its superview and manages its own focus/teardown.
@MainActor
final class CommandPaletteView: NSView, NSTextFieldDelegate {

    private let allCommands: [PaletteCommand]
    private var filtered: [PaletteCommand]
    private var selectedIndex = 0
    private let onClose: () -> Void

    private let panel = NSView()
    private let searchField = NSTextField()
    private let listStack = NSStackView()
    private let scrollView = NSScrollView()
    private var rowViews: [PaletteRowView] = []
    private let emptyLabel = NSTextField(labelWithString: "No matching commands")
    /// Explicit, content-driven height for the scroll area (capped). Without it
    /// the scroll view has no intrinsic height and the panel collapses.
    private var listHeight: NSLayoutConstraint!

    private static let rowHeight: CGFloat = 42
    private static let rowSpacing: CGFloat = 2
    private static let listInset: CGFloat = 16   // stack top+bottom padding
    private static let maxListHeight: CGFloat = 320

    init(commands: [PaletteCommand], onClose: @escaping () -> Void) {
        self.allCommands = commands
        self.filtered = commands
        self.onClose = onClose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // Scrim.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        buildPanel()
        rebuildRows()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// Focus the search field once the view is in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(searchField) }
    }

    // MARK: - Build

    private func buildPanel() {
        let theme = QTheme.current

        panel.wantsLayer = true
        panel.layer?.backgroundColor = theme.bg2Color.cgColor
        panel.layer?.borderColor = theme.borderColor.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.cornerRadius = 14
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        // Search row.
        let magnifier = NSImageView()
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.contentTintColor = theme.accentColor
        magnifier.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Type a command…"
        searchField.font = QTheme.monoFont(size: 15)
        searchField.textColor = theme.fgColor
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let searchRow = NSView()
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(magnifier)
        searchRow.addSubview(searchField)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = theme.borderColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Command list.
        listStack.orientation = .vertical
        listStack.spacing = 2
        listStack.alignment = .leading
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(listStack)

        scrollView.documentView = flipped
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Empty-state label (centered in the scroll area).
        emptyLabel.font = QTheme.monoFont(size: 13)
        emptyLabel.textColor = theme.fg3Color
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(searchRow)
        panel.addSubview(divider)
        panel.addSubview(scrollView)
        panel.addSubview(emptyLabel)

        listHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.maxListHeight)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 96),
            panel.widthAnchor.constraint(equalToConstant: 560),
            listHeight,
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            searchRow.topAnchor.constraint(equalTo: panel.topAnchor),
            searchRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            searchRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            searchRow.heightAnchor.constraint(equalToConstant: 50),

            magnifier.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 16),
            magnifier.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 16),
            magnifier.heightAnchor.constraint(equalToConstant: 16),

            searchField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 11),
            searchField.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            divider.topAnchor.constraint(equalTo: searchRow.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            flipped.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            flipped.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            listStack.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 8),
            listStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 8),
            listStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -8),
            listStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -8),
        ])
    }

    private func rebuildRows() {
        for row in rowViews {
            listStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rowViews.removeAll()

        for (index, command) in filtered.enumerated() {
            let row = PaletteRowView(command: command)
            row.onRun = { [weak self] in self?.run(at: index) }
            row.onHover = { [weak self] in self?.select(index) }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            rowViews.append(row)
        }

        emptyLabel.isHidden = !filtered.isEmpty

        // Size the scroll area to the content, capped so it scrolls beyond that.
        let contentHeight = CGFloat(filtered.count) * (Self.rowHeight + Self.rowSpacing) + Self.listInset
        listHeight.constant = filtered.isEmpty ? 60 : min(contentHeight, Self.maxListHeight)

        selectedIndex = filtered.isEmpty ? -1 : 0
        highlight()
    }

    // MARK: - Selection / running

    private func select(_ index: Int) {
        guard filtered.indices.contains(index) else { return }
        selectedIndex = index
        highlight()
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + filtered.count) % filtered.count
        highlight()
        if rowViews.indices.contains(selectedIndex) {
            rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
        }
    }

    private func highlight() {
        for (i, row) in rowViews.enumerated() { row.setSelected(i == selectedIndex) }
    }

    private func runSelected() {
        run(at: selectedIndex)
    }

    private func run(at index: Int) {
        guard filtered.indices.contains(index) else { return }
        let command = filtered[index]
        onClose()          // tear down first so the action runs against the live UI
        command.run()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = query.isEmpty
            ? allCommands
            : allCommands.filter { $0.label.lowercased().contains(query) }
        rebuildRows()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):        moveSelection(-1); return true
        case #selector(NSResponder.moveDown(_:)):      moveSelection(1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose(); return true
        default: return false
        }
    }

    // MARK: - Scrim click closes

    override func mouseDown(with event: NSEvent) {
        // A click outside the panel dismisses the palette.
        let point = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(point) { onClose() }
    }
}

// MARK: - FlippedView

/// A top-left-origin container so the command list lays out top-down.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - PaletteRowView

/// One command row: glyph chip · label · shortcut. Highlights on hover/selection.
private final class PaletteRowView: NSView {

    var onRun: (() -> Void)?
    var onHover: (() -> Void)?

    private let chip = NSView()
    private let glyphLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let kbdLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    init(command: PaletteCommand) {
        super.init(frame: .zero)
        let theme = QTheme.current
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false

        chip.wantsLayer = true
        chip.layer?.backgroundColor = theme.bg3Color.cgColor
        chip.layer?.borderColor = theme.borderColor.cgColor
        chip.layer?.borderWidth = 1
        chip.layer?.cornerRadius = 7
        chip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)

        glyphLabel.stringValue = command.glyph
        glyphLabel.font = QTheme.monoFont(size: 13, weight: .bold)
        glyphLabel.textColor = theme.accentColor
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(glyphLabel)

        titleLabel.stringValue = command.label
        titleLabel.font = QTheme.monoFont(size: 13.5)
        titleLabel.textColor = theme.fgColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        kbdLabel.stringValue = command.kbd
        kbdLabel.font = QTheme.monoFont(size: 11)
        kbdLabel.textColor = theme.fg3Color
        kbdLabel.alignment = .right
        kbdLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(kbdLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),

            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 26),
            chip.heightAnchor.constraint(equalToConstant: 26),

            glyphLabel.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            glyphLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            kbdLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            kbdLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            kbdLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected
            ? QTheme.current.bg3Color.cgColor
            : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onRun?() }
}
