import AppKit
import ZettyGhostty

/// A transient read-only file peek: scrim + centered panel with a header, the
/// file's text (syntax-highlighted when available) with line numbers, and a
/// footer offering the file to a real editor. Esc or a click outside closes.
///
/// Read-only by construction — there is no write path here. "I want to edit
/// this" is answered by the footer button, not by this view.
///
/// The text is a plain `NSTextView` in an `NSScrollView`, set up exactly like
/// `FileCopyBackSheet` — the one text renderer in this app that is known to
/// work. An earlier version hand-built a TextKit 1 stack so an `NSRulerView`
/// gutter could reach `layoutManager`; text laid out correctly but never
/// composited (even a forced background colour didn't draw). Line numbers are
/// part of the attributed text instead, which costs us numbers-in-copied-text
/// and buys the whole class of bug going away.
@MainActor
final class FileViewerOverlay: NSView {

    private let onClose: () -> Void

    private let panel = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let headerStack = NSStackView()
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let headerDivider = NSView()
    private let footerDivider = NSView()
    private let positionLabel = NSTextField(labelWithString: "")
    private let openPill = NSView()
    private let openButton = NSButton()
    private let diagnosticsButton = NSButton()

    /// Restores the diagnostics button's title after its "Copied" flash;
    /// retained so a second click cancels the first one's restore.
    private var diagnosticsReset: DispatchWorkItem?

    /// Absolute path currently shown — what the footer button acts on.
    /// What's on screen, retained so a scheme switch can re-render it: the body's
    /// colours are baked into the attributed string at render time, so repainting
    /// only the chrome would leave stale foregrounds on a new background.
    private var shownLoaded: FileViewerLoader.Loaded?
    private var shownProjectRoot: String?
    private var shownPath: String?
    private var shownLine: Int?
    private var shownColumn: Int?

    init(onClose: @escaping () -> Void) {
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
        for label in [nameLabel, pathLabel, positionLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            // Single line, always: a wrapped header would push the divider down.
            label.maximumNumberOfLines = 1
        }
        // Only the path gives way when the header is too narrow (truncating by
        // the head, so the filename end stays readable).
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A stack view rather than baseline-aligned constraints: side-by-side is
        // then structural, which is how StatusBarView builds its clusters too.
        headerStack.orientation = .horizontal
        headerStack.alignment = .firstBaseline
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.setViews([nameLabel, pathLabel], in: .leading)

        // Close ✕ — a bare glyph in the header's trailing edge; `fg3` because a
        // dismiss control is idle chrome, not an accented action. Esc still works.
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        closeButton.toolTip = "Close (Esc)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        for divider in [headerDivider, footerDivider] {
            divider.wantsLayer = true
            divider.translatesAutoresizingMaskIntoConstraints = false
        }

        // Mirrors FileCopyBackSheet's diff view: a plain NSTextView, its own
        // background, and no manual frame/autoresizing meddling — the scroll
        // view owns the document view's geometry.
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 10)
        // LOAD-BEARING, and invisible on macOS 26: the clip view widens a
        // document view only through its autoresizing mask, and a bare
        // `NSTextView()` has none. The overlay is built and filled while it is
        // still detached and zero-sized, so without this the text view keeps
        // that 0 width when the panel is finally laid out — the container is 0
        // wide, nothing lays out, and the peek paints a blank panel with the
        // whole file sitting in its storage. macOS 26 widens the document view
        // implicitly, which is why this only ever reproduces on macOS 15.
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

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

        // "Copy diagnostics" — bare `fg3` text, no pill: this is a bug-report
        // affordance, not an action anyone needs day to day, and the one moment
        // it matters most is when the panel above it is blank. So it has to be
        // present and legible without competing with "Open in ▾".
        diagnosticsButton.isBordered = false
        diagnosticsButton.bezelStyle = .inline
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(copyDiagnosticsClicked)
        diagnosticsButton.toolTip = "Copy this peek's diagnostic log for a bug report"
        diagnosticsButton.translatesAutoresizingMaskIntoConstraints = false
        // Give way first: the footer's required chain runs position label →
        // this → Open pill, so on a narrow panel this has to compress rather
        // than break a constraint.
        diagnosticsButton.lineBreakMode = .byTruncatingTail
        diagnosticsButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        panel.addSubview(headerStack)
        panel.addSubview(closeButton)
        panel.addSubview(headerDivider)
        panel.addSubview(scrollView)
        panel.addSubview(footerDivider)
        panel.addSubview(positionLabel)
        panel.addSubview(openPill)
        panel.addSubview(diagnosticsButton)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 72),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -72),
            panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.72),

            headerStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            headerStack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor,
                                                  constant: -10),

            closeButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            closeButton.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            headerDivider.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
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

            // Between the position label and the Open pill, and never on top of
            // either: the position label wins the space it needs, the button
            // truncates rather than pushing the pill off the panel.
            diagnosticsButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: positionLabel.trailingAnchor, constant: 12),
            diagnosticsButton.trailingAnchor.constraint(equalTo: openPill.leadingAnchor,
                                                        constant: -12),
            diagnosticsButton.centerYAnchor.constraint(equalTo: positionLabel.centerYAnchor),

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
        shownLoaded = loaded
        shownProjectRoot = projectRoot
        shownPath = loaded.path
        shownLine = loaded.line
        shownColumn = nil

        let theme = ZTheme.current
        nameLabel.stringValue = (loaded.path as NSString).lastPathComponent
        pathLabel.stringValue = displayPath(loaded.path, projectRoot: projectRoot)

        // An EMPTY run list takes the message branch, not the body branch: a
        // zero-character body paints the panel's background and nothing else,
        // which reads as a broken viewer rather than as "there was nothing to
        // show". The loader always pairs that state with a reason; the `??`
        // is the backstop that keeps a silent blank panel unreachable.
        if let runs = loaded.runs, !runs.isEmpty {
            let body = NSMutableAttributedString()
            // Hoisted: invariant across runs, and a file can have thousands.
            let background = Self.components(of: theme.bg1Color)
            stats = RenderStats()
            for run in runs {
                body.append(NSAttributedString(string: run.text,
                                               attributes: attributes(for: run.style,
                                                                      background: background)))
            }
            textView.textStorage?.setAttributedString(body)
            if let range = lineRange(in: body.string, line: loaded.line) {
                textView.textStorage?.addAttribute(.backgroundColor, value: theme.bg3Color,
                                                   range: range)
                textView.scrollRangeToVisible(range)
            } else {
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
            logBody(body, runs: runs, background: background)
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: loaded.message ?? "Nothing to display",
                attributes: [.font: ZTheme.monoFont(size: 12),
                             .foregroundColor: theme.yellowColor]))
            ZettyLog.viewer.log("""
                show: message branch — "\(loaded.message ?? "Nothing to display")" \
                runs=\(loaded.runs?.count ?? -1)
                """)
            logGeometry()
        }

        var position: [String] = []
        if let line = loaded.line { position.append(":\(line)") }
        if let truncated = loaded.truncatedAtLine {
            position.append("truncated at line \(truncated)")
        }
        positionLabel.stringValue = position.joined(separator: "  ·  ")

        renderOpenButton()
        // A new file means the previous "Copied ✓" no longer refers to what's
        // on screen.
        diagnosticsReset?.cancel()
        renderDiagnosticsButton(copied: false)
        // Content arrives asynchronously, and a pane rebuild in the meantime
        // can have handed focus back to a terminal — reclaim it so Esc works.
        if window?.firstResponder !== textView { window?.makeFirstResponder(textView) }
    }

    /// Character range of a 1-based line, or nil when there's no target line or
    /// the file has fewer lines than that.
    private func lineRange(in text: String, line: Int?) -> NSRange? {
        guard let line, line > 0 else { return nil }
        let full = text as NSString
        var start = 0
        var current = 1
        while current < line {
            guard start < full.length else { return nil }
            let next = NSMaxRange(full.lineRange(for: NSRange(location: start, length: 0)))
            if next == start { return nil }
            start = next
            current += 1
        }
        guard start <= full.length else { return nil }
        return full.lineRange(for: NSRange(location: start, length: 0))
    }

    // MARK: - Diagnostics
    //
    // A blank peek looks identical whether the text is missing, transparent, or
    // laid out somewhere off screen, and it is only ever reported as a
    // screenshot of an empty panel. These record which of those it was — what
    // the colours resolved to, and what geometry the text view ended up with.

    /// What `color(for:background:)` decided while rendering the current body.
    private struct RenderStats {
        /// Runs whose colour was too close to `bg1` and fell back to `fg`.
        var illegible = 0
        /// Runs with no SGR colour at all, drawn in `fg`.
        var uncoloured = 0
        /// Distinct foreground hexes actually used, capped so a rainbow file
        /// can't flood the log.
        var hexes: [String] = []

        mutating func note(_ color: NSColor?) {
            guard let color else { return }
            let hex = FileViewerOverlay.hex(of: color)
            guard !hexes.contains(hex), hexes.count < 8 else { return }
            hexes.append(hex)
        }
    }

    private var stats = RenderStats()

    /// `nonisolated` so `RenderStats.note` — a plain struct mutation on
    /// whichever actor is rendering — can reach it.
    private nonisolated static func hex(of color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "?" }
        return String(format: "%02x%02x%02x",
                      Int((srgb.redComponent * 255).rounded()),
                      Int((srgb.greenComponent * 255).rounded()),
                      Int((srgb.blueComponent * 255).rounded()))
    }

    /// Summarises a rendered body: enough to tell real-but-invisible text from
    /// text that was never there. The file's own characters are deliberately
    /// NOT logged — only how many there are, and how many are visible ink.
    private func logBody(_ body: NSAttributedString, runs: [ANSIRun],
                         background: ColorLegibility.Components?) {
        let ink = body.string.reduce(into: 0) { count, character in
            if !character.isWhitespace { count += 1 }
        }
        ZettyLog.viewer.log("""
            show: body branch runs=\(runs.count) \
            chars=\(body.length) ink=\(ink) \
            storage=\(self.textView.textStorage.map { "\($0.length)" } ?? "nil") \
            bg1=#\(FileViewerOverlay.hex(of: ZTheme.current.bg1Color)) \
            bgKnown=\(background != nil) \
            illegible=\(self.stats.illegible) \
            uncoloured=\(self.stats.uncoloured) \
            fgs=[\(self.stats.hexes.joined(separator: " "))] \
            font=\(ZTheme.monoFont(size: 12).fontName)@\(ZTheme.monoFont(size: 12).pointSize)
            """)
        logGeometry()
    }

    /// Where the text actually landed, read one run-loop turn later so Auto
    /// Layout has run — at `show()` time the panel may still be zero-sized. A
    /// laid-out text view with real content but an empty visible rect is a
    /// different bug from one with no content at all.
    private func logGeometry() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // `textLayoutManager` is read, never `layoutManager` — touching the
            // latter downgrades the view to TextKit 1.
            ZettyLog.viewer.log("""
                show: geometry text=\(NSStringFromRect(self.textView.frame)) \
                clip=\(NSStringFromRect(self.scrollView.contentView.bounds)) \
                visible=\(NSStringFromRect(self.scrollView.documentVisibleRect)) \
                panel=\(NSStringFromRect(self.panel.frame)) \
                overlay=\(NSStringFromRect(self.frame)) \
                textKit2=\(self.textView.textLayoutManager != nil) \
                hidden=\(self.textView.isHiddenOrHasHiddenAncestor) \
                alpha=\(self.alphaValue) \
                window=\(self.window != nil)
                """)
        }
    }

    private func attributes(for style: ANSIStyle,
                            background: ColorLegibility.Components?) -> [NSAttributedString.Key: Any] {
        let theme = ZTheme.current
        let font = ZTheme.monoFont(size: 12, weight: style.bold ? .semibold : .regular)
        let foreground = color(for: style.foreground, background: background) ?? theme.fgColor
        stats.note(foreground)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.italic ? italicized(font) : font,
            .foregroundColor: foreground,
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
    ///
    /// Truecolor and 256-cube runs can't be mapped that way — they're ABSOLUTE
    /// colours from the highlighter's own theme, picked with no knowledge of
    /// Zetty's scheme — so they're passed through, but only if they can actually
    /// be seen against `bg1`. `HighlightTheme` normally keeps the highlighter on
    /// the right axis; this is the backstop for the commands it can't configure,
    /// because a wrong hue is cosmetic while invisible text is an empty panel.
    /// Returning nil hands the run to the caller's `fg` fallback.
    /// sRGB components of `color`, or nil when it can't be converted (a pattern
    /// or catalog colour) — the legibility check is then skipped rather than
    /// guessed at.
    private static func components(of color: NSColor) -> ColorLegibility.Components? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    private func color(for ansi: ANSIColor?,
                       background: ColorLegibility.Components?) -> NSColor? {
        let theme = ZTheme.current
        switch ansi {
        case .none:
            stats.uncoloured += 1
            return nil
        case .rgb(let r, let g, let b):
            let color = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                                blue: CGFloat(b) / 255, alpha: 1)
            guard let background else { return color }
            let legible = ColorLegibility.isLegible(
                foreground: (Double(r) / 255, Double(g) / 255, Double(b) / 255),
                background: background)
            if !legible { stats.illegible += 1 }
            return legible ? color : nil
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

    @objc private func closeClicked() { onClose() }

    @objc private func openClicked() {
        guard let path = shownPath else { return }
        let fileURL = URL(fileURLWithPath: path)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        let editors = EditorCatalog.installed()

        let menu = NSMenu()
        for editor in editors {
            let isDefault = defaultApp.map { $0.standardizedFileURL == editor.standardizedFileURL } ?? false
            let name = EditorCatalog.displayName(of: editor)
            let item = NSMenuItem(title: isDefault ? "\(name) (default)" : name,
                                  action: #selector(openInEditor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = editor
            item.image = EditorCatalog.icon(for: editor, size: 14)
            menu.addItem(item)
        }
        // Whatever the file is now, it's text — so editors lead and the system
        // default app is the secondary option (handy for e.g. .md in Marked).
        if let item = defaultAppItem(defaultApp, among: editors) {
            if !editors.isEmpty { menu.addItem(.separator()) }
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: "No apps found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: openButton)
    }

    /// The system default app for this file, as a menu item — nil when it can't
    /// be resolved, or when it's already listed among the editors (which get a
    /// "(default)" suffix instead, so it never appears twice).
    private func defaultAppItem(_ defaultApp: URL?, among editors: [URL]) -> NSMenuItem? {
        guard let defaultApp else { return nil }
        let alreadyListed = editors.contains { $0.standardizedFileURL == defaultApp.standardizedFileURL }
        guard !alreadyListed else { return nil }
        let item = NSMenuItem(title: "\(EditorCatalog.displayName(of: defaultApp)) (default)",
                              action: #selector(openWithDefaultApp(_:)), keyEquivalent: "")
        item.target = self
        item.image = EditorCatalog.icon(for: defaultApp, size: 14)
        return item
    }

    /// Hands the file to whatever the system opens it with — Preview for a PDF,
    /// an image viewer for a PNG. No line addressing, by nature.
    @objc private func openWithDefaultApp(_ sender: NSMenuItem) {
        guard let path = shownPath else { return }
        let url = URL(fileURLWithPath: path)
        // Reveal rather than fail silently if nothing claims the type.
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        onClose()
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

    /// Puts the recent diagnostics on the clipboard, so a "the peek is blank"
    /// report is a paste rather than a `log show` incantation typed into a
    /// terminal the reporter may not think to open.
    @objc private func copyDiagnosticsClicked() {
        let report = ZettyLog.report()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        ZettyLog.viewer.log("diagnostics copied (\(report.count) chars)")

        diagnosticsReset?.cancel()
        renderDiagnosticsButton(copied: true)
        let reset = DispatchWorkItem { [weak self] in self?.renderDiagnosticsButton(copied: false) }
        diagnosticsReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: reset)
    }

    /// `fg3` at rest, semantic `green` while confirming — the same "it worked"
    /// colour the status dots use. Assignments are user-driven (click, theme,
    /// each peek), never per-refresh, so `attributedTitle`'s per-assignment KVO
    /// cost stays bounded.
    private func renderDiagnosticsButton(copied: Bool) {
        let theme = ZTheme.current
        diagnosticsButton.attributedTitle = NSAttributedString(
            string: copied ? "Copied ✓" : "Copy diagnostics",
            attributes: [
                .font: ZTheme.monoFont(size: 11),
                .foregroundColor: copied ? theme.greenColor : theme.fg3Color,
            ])
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
        closeButton.contentTintColor = theme.fg3Color
        textView.backgroundColor = theme.bg1Color
        openPill.layer?.backgroundColor = theme.bg3Color.cgColor
        openPill.layer?.borderColor = theme.borderColor.cgColor
        renderOpenButton()
        renderDiagnosticsButton(copied: false)
        // Re-render the body so its baked-in colours follow the new scheme.
        // `show` never calls back into `applyTheme`, so this can't recurse.
        if let shownLoaded { show(shownLoaded, projectRoot: shownProjectRoot) }
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
