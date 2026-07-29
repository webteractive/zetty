import AppKit
import ZettyCore

/// A transient read-only file peek: scrim + centered panel with a header, the
/// file's text (syntax-highlighted when available), a line-number gutter, and
/// a footer offering the file to a real editor. Esc or a click outside closes.
///
/// Read-only by construction — there is no write path here. "I want to edit
/// this" is answered by the footer button, not by this view.
@MainActor
final class FileViewerOverlay: NSView {

    private let onClose: () -> Void

    private let panel = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView: NSTextView
    private let headerDivider = NSView()
    private let footerDivider = NSView()
    private let positionLabel = NSTextField(labelWithString: "")
    private let openPill = NSView()
    private let openButton = NSButton()

    private var ruler: LineNumberRuler?
    /// Absolute path currently shown — what the footer button acts on.
    private var shownPath: String?
    private var shownLine: Int?
    private var shownColumn: Int?

    init(onClose: @escaping () -> Void) {
        // TextKit 1 stack: TextKit 2 (the macOS 14+ default) has no
        // `layoutManager`, which the line-number ruler needs.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)

        self.onClose = onClose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        buildPanel()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(textView) }
    }

    // MARK: - Build

    private func buildPanel() {
        panel.wantsLayer = true
        panel.layer?.borderWidth = 1
        panel.layer?.cornerRadius = 14
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        nameLabel.lineBreakMode = .byTruncatingTail
        pathLabel.lineBreakMode = .byTruncatingHead
        positionLabel.lineBreakMode = .byClipping
        for label in [nameLabel, pathLabel, positionLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for divider in [headerDivider, footerDivider] {
            divider.wantsLayer = true
            divider.translatesAutoresizingMaskIntoConstraints = false
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        self.ruler = ruler

        // "Open in ▾" — the same bordered pill idiom as the status bar's
        // switchers, but scoped to the file rather than the pane's directory.
        openButton.isBordered = false
        openButton.bezelStyle = .inline
        openButton.imagePosition = .imageTrailing
        openButton.imageHugsTitle = true
        openButton.target = self
        openButton.action = #selector(openClicked)
        openButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Open in…")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openPill.wantsLayer = true
        openPill.layer?.cornerRadius = 10
        openPill.layer?.borderWidth = 1
        openPill.translatesAutoresizingMaskIntoConstraints = false
        openPill.addSubview(openButton)

        panel.addSubview(nameLabel)
        panel.addSubview(pathLabel)
        panel.addSubview(headerDivider)
        panel.addSubview(scrollView)
        panel.addSubview(footerDivider)
        panel.addSubview(positionLabel)
        panel.addSubview(openPill)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 72),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -72),
            panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.72),

            nameLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            nameLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -16),
            pathLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),

            headerDivider.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 12),
            headerDivider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),
            footerDivider.bottomAnchor.constraint(equalTo: positionLabel.topAnchor, constant: -10),

            positionLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            positionLabel.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),

            openPill.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            openPill.centerYAnchor.constraint(equalTo: positionLabel.centerYAnchor),
            openPill.heightAnchor.constraint(equalToConstant: 20),
            openButton.leadingAnchor.constraint(equalTo: openPill.leadingAnchor, constant: 9),
            openButton.trailingAnchor.constraint(equalTo: openPill.trailingAnchor, constant: -8),
            openButton.centerYAnchor.constraint(equalTo: openPill.centerYAnchor),
        ])
    }

    // MARK: - Content

    /// Renders a loaded file. Calling this again replaces the content — at most
    /// one peek exists per window.
    func show(_ loaded: FileViewerLoader.Loaded, projectRoot: String?) {
        shownPath = loaded.path
        shownLine = loaded.line
        shownColumn = nil

        let theme = ZTheme.current
        nameLabel.stringValue = (loaded.path as NSString).lastPathComponent
        pathLabel.stringValue = displayPath(loaded.path, projectRoot: projectRoot)

        let body = NSMutableAttributedString()
        if let runs = loaded.runs {
            for run in runs {
                body.append(NSAttributedString(string: run.text, attributes: attributes(for: run.style)))
            }
        } else if let message = loaded.message {
            body.append(NSAttributedString(string: message, attributes: [
                .font: ZTheme.monoFont(size: 12),
                .foregroundColor: theme.yellowColor,
            ]))
        }
        textView.textStorage?.setAttributedString(body)

        var position: [String] = []
        if let line = loaded.line { position.append(":\(line)") }
        if let truncated = loaded.truncatedAtLine {
            position.append("truncated at line \(truncated)")
        }
        positionLabel.stringValue = position.joined(separator: "  ·  ")

        ruler?.highlightedLine = loaded.line
        renderOpenButton()
        if let line = loaded.line { highlightAndScroll(to: line) }
        ruler?.needsDisplay = true
        // Content arrives asynchronously, and a pane rebuild in the meantime
        // can have handed focus back to a terminal — reclaim it so Esc works.
        if window?.firstResponder !== textView { window?.makeFirstResponder(textView) }
    }

    /// Marks the target line with the selection surface and scrolls it into
    /// view, roughly centered.
    private func highlightAndScroll(to line: Int) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        var index = 0
        var current = 1
        while current < line, index < text.length {
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            current += 1
        }
        guard index <= text.length else { return }
        let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
        storage.addAttribute(.backgroundColor, value: ZTheme.current.bg3Color, range: lineRange)
        textView.scrollRangeToVisible(lineRange)
        // Center it rather than leaving it pinned to an edge.
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange,
                                                      actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let visible = scrollView.contentView.bounds.height
            let target = max(0, rect.midY - visible / 2)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func attributes(for style: ANSIStyle) -> [NSAttributedString.Key: Any] {
        let theme = ZTheme.current
        let font = ZTheme.monoFont(size: 12, weight: style.bold ? .semibold : .regular)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.italic ? italicized(font) : font,
            .foregroundColor: color(for: style.foreground) ?? theme.fgColor,
        ]
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private func italicized(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Palette indexes 0–15 map onto `ZTheme` so highlighting tracks the
    /// active scheme instead of baking in xterm's defaults.
    private func color(for ansi: ANSIColor?) -> NSColor? {
        let theme = ZTheme.current
        switch ansi {
        case .none:
            return nil
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        case .indexed(let index):
            switch index {
            case 1, 9:   return theme.redColor
            case 2, 10:  return theme.greenColor
            case 3, 11:  return theme.yellowColor
            case 4, 12:  return theme.accentColor
            case 5, 13:  return theme.purpleColor
            case 6, 14:  return theme.accentColor
            case 7, 15:  return theme.fgColor
            default:     return theme.fg3Color   // 0/8: black + bright black
            }
        }
    }

    private func displayPath(_ path: String, projectRoot: String?) -> String {
        if let projectRoot, path.hasPrefix(projectRoot + "/") {
            return String(path.dropFirst(projectRoot.count + 1))
        }
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - Open in editor

    @objc private func openClicked() {
        guard shownPath != nil else { return }
        let menu = NSMenu()
        for editor in EditorCatalog.installed() {
            let item = NSMenuItem(title: EditorCatalog.displayName(of: editor),
                                  action: #selector(openInEditor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = editor
            item.image = EditorCatalog.icon(for: editor, size: 14)
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: "No editors found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: openButton)
    }

    @objc private func openInEditor(_ sender: NSMenuItem) {
        guard let editor = sender.representedObject as? URL, let path = shownPath else { return }
        if let url = EditorCatalog.openURL(for: editor, file: path,
                                          line: shownLine, column: shownColumn) {
            NSWorkspace.shared.open(url)
        } else {
            // No line-addressing scheme — a plain open still beats nothing.
            NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                    withApplicationAt: editor,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        onClose()
    }

    private func renderOpenButton() {
        let theme = ZTheme.current
        openButton.attributedTitle = NSAttributedString(
            string: "Open in ",
            attributes: [
                .font: ZTheme.monoFont(size: 11, weight: .medium),
                .foregroundColor: theme.fgColor,
            ])
        openButton.contentTintColor = theme.fg2Color
        openButton.toolTip = "Open this file in an editor"
    }

    // MARK: - Theme

    func applyTheme() {
        let theme = ZTheme.current
        panel.layer?.backgroundColor = theme.bg2Color.cgColor
        panel.layer?.borderColor = theme.borderColor.cgColor
        headerDivider.layer?.backgroundColor = theme.borderColor.cgColor
        footerDivider.layer?.backgroundColor = theme.borderColor.cgColor
        nameLabel.font = ZTheme.monoFont(size: 12, weight: .medium)
        nameLabel.textColor = theme.fgColor
        pathLabel.font = ZTheme.monoFont(size: 11)
        pathLabel.textColor = theme.fg3Color
        positionLabel.font = ZTheme.monoFont(size: 11)
        positionLabel.textColor = theme.fg2Color
        openPill.layer?.backgroundColor = theme.bg3Color.cgColor
        openPill.layer?.borderColor = theme.borderColor.cgColor
        renderOpenButton()
        ruler?.needsDisplay = true
    }

    // MARK: - Dismissal

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(point) { onClose() }
    }

    override func keyDown(with event: NSEvent) {
        // 53 = Escape. The read-only text view is the first responder, so this
        // is the overlay's own dismissal path.
        if event.keyCode == 53 { onClose() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onClose() }
}

// MARK: - LineNumberRuler

/// Left gutter drawing 1-based line numbers aligned to the text view's lines.
/// Requires the TextKit 1 stack built in `FileViewerOverlay.init`.
private final class LineNumberRuler: NSRulerView {

    /// Drawn in the accent colour — the peeked line.
    var highlightedLine: Int?

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 56
    }

    // NSRulerView's is non-failable, unlike NSView's.
    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError("not supported") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let clip = scrollView?.contentView
        else { return }

        let theme = ZTheme.current
        theme.bg1Color.setFill()
        rect.fill()
        theme.borderColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let text = textView.string as NSString
        guard text.length > 0 else { return }
        let visible = clip.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Line number of the first visible character.
        var lineNumber = 1
        if charRange.location > 0 {
            text.enumerateSubstrings(in: NSRange(location: 0, length: charRange.location),
                                     options: [.byLines, .substringNotRequired]) { _, _, _, _ in
                lineNumber += 1
            }
        }

        var index = charRange.location
        while index <= NSMaxRange(charRange), index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var effective = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                          effectiveRange: &effective)
            let isTarget = lineNumber == highlightedLine
            let attributes: [NSAttributedString.Key: Any] = [
                .font: ZTheme.monoFont(size: 11, weight: isTarget ? .semibold : .regular),
                .foregroundColor: isTarget ? theme.accentColor : theme.fg3Color,
            ]
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + textView.textContainerInset.height - visible.minY
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y),
                       withAttributes: attributes)

            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next == index { break }   // guard against a zero-length final line
            index = next
        }
    }
}
