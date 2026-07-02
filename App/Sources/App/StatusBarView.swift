import AppKit
import ZettyCore

// MARK: - StatusBarView

/// The bottom status strip (handoff: 28pt, `bg0`, mono 11). Three zones:
/// a left **git** cluster (branch · ↑ahead ↓behind · ●changes), the focused
/// pane's working directory centered, and a right cluster of ambient info +
/// switchers: appearance mode (click to cycle), color scheme (click to cycle),
/// shell, and libghostty version.
///
/// The view is dumb: `update(...)` / `updateGit(...)` set content and
/// `applyTheme()` re-reads colors/fonts; user intent is reported via closures.
@MainActor
final class StatusBarView: NSView {

    /// Selects an appearance axis (system / dark / light) from the status-bar menu.
    var onSelectAppearance: ((AppearanceMode) -> Void)?
    /// Selects a color scheme (within the current axis) from the status-bar menu.
    var onSelectScheme: ((QColorScheme) -> Void)?
    /// Shows the "Open in…" picker (editors + Finder); opening happens only
    /// when an item is selected. The anchor view positions the menu.
    var onShowEditorMenu: ((NSView) -> Void)?

    private let topBorder = NSView()

    // Left: git.
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let aheadLabel = NSTextField(labelWithString: "")
    private let behindLabel = NSTextField(labelWithString: "")
    private let changesLabel = NSTextField(labelWithString: "")
    private let leftStack = NSStackView()

    // Center: working directory.
    private let cwdLabel = NSTextField(labelWithString: "")

    // Right: "Open ▾" pill · appearance · scheme · shell · libghostty.
    private let editorPill = NSView()
    private let editorButton = NSButton()
    private let appearanceButton = NSButton()
    private let sep0 = NSTextField(labelWithString: "·")
    private let schemeDot = NSView()
    private let schemeButton = NSButton()
    private let sep1 = NSTextField(labelWithString: "·")
    private let shellLabel = NSTextField(labelWithString: "")
    private let sep2 = NSTextField(labelWithString: "·")
    private let ghosttyLabel = NSTextField(labelWithString: "")
    private let rightStack = NSStackView()

    private var appearanceMode = "System"

    private var plainLabels: [NSTextField] {
        [branchLabel, aheadLabel, behindLabel, changesLabel,
         cwdLabel, sep0, sep1, shellLabel, sep2, ghosttyLabel]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        for label in plainLabels {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        cwdLabel.lineBreakMode = .byTruncatingHead
        cwdLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        branchIcon.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch",
                                       accessibilityDescription: "Git branch")
            branchIcon.imageScaling = .scaleProportionallyDown
        }

        schemeDot.wantsLayer = true
        schemeDot.layer?.cornerRadius = 3.5
        schemeDot.translatesAutoresizingMaskIntoConstraints = false

        topBorder.wantsLayer = true
        topBorder.translatesAutoresizingMaskIntoConstraints = false

        configureSwitch(appearanceButton, action: #selector(appearanceClicked))
        appearanceButton.imagePosition = .imageLeading
        appearanceButton.imageHugsTitle = true
        configureSwitch(schemeButton, action: #selector(schemeClicked))
        // "Open ▾" — a bordered pill (bg2 surface) so it reads as a button,
        // not another status field. Clicking shows the Open-in picker; the
        // action happens only on selection.
        configureSwitch(editorButton, action: #selector(editorClicked))
        editorButton.imagePosition = .imageTrailing
        editorButton.imageHugsTitle = true
        if #available(macOS 11.0, *) {
            editorButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Open in…")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        }
        editorPill.wantsLayer = true
        editorPill.layer?.cornerRadius = 10
        editorPill.layer?.borderWidth = 1
        editorPill.translatesAutoresizingMaskIntoConstraints = false
        editorPill.addSubview(editorButton)
        NSLayoutConstraint.activate([
            editorPill.heightAnchor.constraint(equalToConstant: 20),
            editorButton.leadingAnchor.constraint(equalTo: editorPill.leadingAnchor, constant: 9),
            editorButton.trailingAnchor.constraint(equalTo: editorPill.trailingAnchor, constant: -8),
            editorButton.centerYAnchor.constraint(equalTo: editorPill.centerYAnchor),
        ])

        configureStack(leftStack, views: [branchIcon, branchLabel, aheadLabel, behindLabel, changesLabel])
        configureStack(rightStack, views: [editorPill, appearanceButton, sep0, schemeDot, schemeButton, sep1, shellLabel, sep2, ghosttyLabel])
        rightStack.setCustomSpacing(10, after: editorPill)

        addSubview(topBorder)
        addSubview(leftStack)
        addSubview(cwdLabel)
        addSubview(rightStack)

        let cwdCenter = cwdLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        cwdCenter.priority = .defaultLow

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            cwdLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            cwdCenter,
            cwdLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
            cwdLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -12),

            branchIcon.widthAnchor.constraint(equalToConstant: 11),
            branchIcon.heightAnchor.constraint(equalToConstant: 11),
            schemeDot.widthAnchor.constraint(equalToConstant: 7),
            schemeDot.heightAnchor.constraint(equalToConstant: 7),
        ])

        updateGit(.none)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    private func configureStack(_ stack: NSStackView, views: [NSView]) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews(views, in: .leading)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.setHuggingPriority(.required, for: .horizontal)
    }

    private func configureSwitch(_ button: NSButton, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Actions

    /// Pops up an appearance picker (System / Dark / Light) above the button.
    @objc private func appearanceClicked() {
        let menu = NSMenu()
        for mode in [AppearanceMode.system, .dark, .light] {
            let item = NSMenuItem(title: mode.rawValue.capitalized,
                                  action: #selector(pickAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode.rawValue.capitalized == appearanceMode) ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, from: appearanceButton)
    }

    /// Pops up a scheme picker for the current axis above the button.
    @objc private func schemeClicked() {
        let menu = NSMenu()
        let scoped = QTheme.current.isDark ? QColorScheme.darkSchemes : QColorScheme.lightSchemes
        for scheme in scoped {
            let item = NSMenuItem(title: scheme.displayName,
                                  action: #selector(pickScheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scheme.rawValue
            item.state = (scheme == QTheme.scheme) ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, from: schemeButton)
    }

    private func popUp(_ menu: NSMenu, from button: NSButton) {
        // Anchor above the button (status bar sits at the window bottom).
        let point = NSPoint(x: 0, y: -6)
        menu.popUp(positioning: nil, at: point, in: button)
    }

    @objc private func pickAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AppearanceMode(rawValue: raw) else { return }
        onSelectAppearance?(mode)
    }

    @objc private func pickScheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let scheme = QColorScheme(rawValue: raw) else { return }
        onSelectScheme?(scheme)
    }

    @objc private func editorClicked() {
        onShowEditorMenu?(editorPill)
    }

    // MARK: - Content

    func update(cwd: String, appearance: String, scheme: String, shell: String, ghostty: String) {
        cwdLabel.stringValue = cwd
        appearanceMode = appearance
        shellLabel.stringValue = shell
        ghosttyLabel.stringValue = ghostty
        styleAppearanceButton()
        styleSchemeButton(scheme)
    }

    func updateGit(_ status: GitStatus) {
        let show = status.isRepo && !status.branch.isEmpty
        branchIcon.isHidden = !show
        branchLabel.isHidden = !show
        branchLabel.stringValue = status.branch

        aheadLabel.isHidden = !(show && status.ahead > 0)
        aheadLabel.stringValue = "↑\(status.ahead)"
        behindLabel.isHidden = !(show && status.behind > 0)
        behindLabel.stringValue = "↓\(status.behind)"
        changesLabel.isHidden = !(show && status.changes > 0)
        changesLabel.stringValue = "●\(status.changes)"
    }

    // MARK: - Theme

    func applyTheme() {
        let theme = QTheme.current
        layer?.backgroundColor = theme.bg0Color.cgColor
        topBorder.layer?.backgroundColor = theme.borderColor.cgColor
        schemeDot.layer?.backgroundColor = theme.accentColor.cgColor
        branchIcon.contentTintColor = theme.purpleColor

        let font = QTheme.monoFont(size: 11)
        for label in plainLabels { label.font = font }

        cwdLabel.textColor = theme.fg2Color
        branchLabel.textColor = theme.purpleColor
        aheadLabel.textColor = theme.greenColor
        behindLabel.textColor = theme.redColor
        changesLabel.textColor = theme.yellowColor
        shellLabel.textColor = theme.fg2Color
        ghosttyLabel.textColor = theme.fg2Color
        sep0.textColor = theme.fg3Color
        sep1.textColor = theme.fg3Color
        sep2.textColor = theme.fg3Color
        editorPill.layer?.backgroundColor = theme.bg2Color.cgColor
        editorPill.layer?.borderColor = theme.borderColor.cgColor
        editorButton.contentTintColor = theme.fg2Color
        editorButton.attributedTitle = NSAttributedString(
            string: "Open ",
            attributes: [
                .font: QTheme.monoFont(size: 11, weight: .medium),
                .foregroundColor: theme.fgColor,
            ]
        )
        editorButton.toolTip = "Open the focused pane's directory in an editor or Finder"

        styleAppearanceButton()
        styleSchemeButton(schemeButton.title)
    }

    private func styleAppearanceButton() {
        let icon: String
        switch appearanceMode.lowercased() {
        case "dark":  icon = "moon.fill"
        case "light": icon = "sun.max.fill"
        default:      icon = "circle.lefthalf.filled"
        }
        appearanceButton.image = NSImage(systemSymbolName: icon, accessibilityDescription: appearanceMode)
        appearanceButton.contentTintColor = QTheme.current.fg2Color
        appearanceButton.attributedTitle = NSAttributedString(
            string: " \(appearanceMode)",
            attributes: [
                .font: QTheme.monoFont(size: 11),
                .foregroundColor: QTheme.current.fg2Color,
            ]
        )
        appearanceButton.toolTip = "Appearance: \(appearanceMode) — click to cycle"
    }

    private func styleSchemeButton(_ name: String) {
        schemeButton.attributedTitle = NSAttributedString(
            string: name,
            attributes: [
                .font: QTheme.monoFont(size: 11),
                .foregroundColor: QTheme.current.accentColor,
            ]
        )
        schemeButton.toolTip = "Color scheme: \(name) — click to cycle (⇧⌘T)"
    }
}
