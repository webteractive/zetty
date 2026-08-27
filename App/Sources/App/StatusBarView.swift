import AppKit
import ZettyGhostty

// MARK: - StatusBarView

/// The bottom status strip (handoff: 28pt, `bg0`, mono 11). Two zones:
/// a left cluster — key-layer mode chips, the focused pane's working
/// directory, then git (branch · ↑ahead ↓behind · ●changes) — and a right
/// cluster of ambient info + switchers: appearance mode (click to cycle),
/// color scheme (click to cycle), shell, and libghostty version.
///
/// The view is dumb: `update(...)` / `updateGit(...)` set content and
/// `applyTheme()` re-reads colors/fonts; user intent is reported via closures.
@MainActor
final class StatusBarView: NSView {

    /// Selects an appearance axis (system / dark / light) from the status-bar menu.
    var onSelectAppearance: ((AppearanceMode) -> Void)?
    /// Selects a color scheme (within the current axis) from the status-bar menu.
    var onSelectScheme: ((ZColorScheme) -> Void)?
    /// Shows the "Open in…" picker (editors + Finder); opening happens only
    /// when an item is selected. The anchor view positions the menu.
    var onShowEditorMenu: ((NSView) -> Void)?

    private let topBorder = NSView()

    // Leading: key-layer mode chips (PREFIX / COPY while active, ZOOM while
    // a pane is zoomed). Accent-glow pills per the design rules — accent
    // marks the active mode, fills stay on the bg3 surface.
    private let modeChip = NSTextField(labelWithString: "")
    private let zoomChip = NSTextField(labelWithString: " ZOOM ")
    private let broadcastPill = NSView()
    private let broadcastButton = NSButton()

    /// The focused pane's agent account. Hidden entirely when no accounts are
    /// configured, so a user who never creates one sees no new chrome.
    private let accountPill = NSView()
    private let accountButton = NSButton()
    private var shownAccount: AccountResolution?
    /// Opens Settings → Accounts; the chip is the discoverable way in.
    var onAccountClicked: (() -> Void)?
    private var shownBroadcastScope: BroadcastScope = .off
    /// Clicked to cycle broadcast scope (Off → Tab → Project → Agents → Workspace).
    var onBroadcastClicked: (() -> Void)?

    // Left: working directory, then git.
    private let cwdLabel = NSTextField(labelWithString: "")
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let aheadLabel = NSTextField(labelWithString: "")
    private let behindLabel = NSTextField(labelWithString: "")
    private let changesLabel = NSTextField(labelWithString: "")
    private let leftStack = NSStackView()

    // Right: "Open ▾" pill · appearance · scheme · shell · zetty build · libghostty.
    private let editorPill = NSView()
    /// Version pill (bottom-right): shows the build version as a button; click
    /// checks for updates. Switches to an accent "↑ Update X" state when a newer
    /// release is known.
    private let versionButton = NSButton()
    private let versionPill = NSView()
    private var baseVersion = ""
    private var pendingUpdate: AvailableUpdate?
    var onUpdateClicked: (() -> Void)?

    /// "Install/Reinstall CLI" pill — hidden unless the CLI symlink is stale.
    private let cliButton = NSButton()
    private let cliPill = NSView()
    private var cliStatus: CLIStatus = .current
    var onCLIReinstallClicked: (() -> Void)?

    private let editorButton = NSButton()
    private let appearanceButton = NSButton()
    private let sep0 = NSTextField(labelWithString: "·")
    private let schemeDot = NSView()
    private let schemeButton = NSButton()
    private let sep1 = NSTextField(labelWithString: "·")
    private let shellLabel = NSTextField(labelWithString: "")
    private let sep2 = NSTextField(labelWithString: "·")
    private let sep3 = NSTextField(labelWithString: "·")
    private let ghosttyLabel = NSTextField(labelWithString: "")
    private let rightStack = NSStackView()

    private var appearanceMode = "System"

    // MARK: - Render caches
    //
    // The status bar is refreshed on every chrome refresh, and `NSButton`'s
    // `attributedTitle` setter leaks an AppKit KVO dependency record per
    // assignment (`NSKeyValueDependency` + context + two blocks). At a few
    // refreshes a second that reached ~3M live objects / ~550MB after two days
    // of uptime. Each renderer below therefore no-ops when its inputs are
    // unchanged; `invalidateRenderCaches()` forces them through on a theme
    // change, where the inputs are equal but the colors are not.

    private var renderedAppearance: String?
    private var renderedScheme: String?
    private var renderedVersion: String?
    private var renderedCLIStatus: CLIStatus?
    private var renderedBroadcastScope: BroadcastScope?
    /// Cached by account id AND emptiness, so the chip re-renders when the
    /// account changes or the last account is removed.
    private var renderedAccountToken: String?

    /// Drops every cached render token so the next call actually re-renders.
    private func invalidateRenderCaches() {
        renderedAppearance = nil
        renderedScheme = nil
        renderedVersion = nil
        renderedCLIStatus = nil
        renderedBroadcastScope = nil
        // The palette flips its dark/light variant while the id is unchanged —
        // without this the chip would freeze in the old scheme's color.
        renderedAccountToken = nil
    }

    private var plainLabels: [NSTextField] {
        [branchLabel, aheadLabel, behindLabel, changesLabel,
         cwdLabel, sep0, sep1, shellLabel, sep2, sep3, ghosttyLabel]
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

        for chip in [modeChip, zoomChip] {
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 4
            chip.alignment = .center
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.isHidden = true
        }

        // Broadcast: a clickable pill (like "Open ▾") showing the antenna icon
        // + scope; clicking cycles the scope. Always visible so it doubles as
        // the on/off control.
        configureSwitch(broadcastButton, action: #selector(broadcastClicked))
        broadcastButton.imagePosition = .imageLeading
        broadcastButton.imageHugsTitle = true
        broadcastPill.wantsLayer = true
        broadcastPill.layer?.cornerRadius = 10
        broadcastPill.layer?.borderWidth = 1
        broadcastPill.layer?.shadowOffset = .zero
        broadcastPill.translatesAutoresizingMaskIntoConstraints = false
        broadcastPill.addSubview(broadcastButton)
        NSLayoutConstraint.activate([
            broadcastPill.heightAnchor.constraint(equalToConstant: 20),
            broadcastButton.leadingAnchor.constraint(equalTo: broadcastPill.leadingAnchor, constant: 9),
            broadcastButton.trailingAnchor.constraint(equalTo: broadcastPill.trailingAnchor, constant: -9),
            broadcastButton.centerYAnchor.constraint(equalTo: broadcastPill.centerYAnchor),
        ])

        accountPill.wantsLayer = true
        accountPill.layer?.cornerRadius = 10
        accountPill.layer?.borderWidth = 1
        accountPill.translatesAutoresizingMaskIntoConstraints = false
        configureSwitch(accountButton, action: #selector(accountClicked))
        // Both are REQUIRED when a button carries an image and a title: the
        // default position is `.imageOverlaps`, which draws the glyph on top of
        // the label instead of beside it. Same pairing as the broadcast pill.
        accountButton.imagePosition = .imageLeading
        accountButton.imageHugsTitle = true
        accountPill.addSubview(accountButton)
        NSLayoutConstraint.activate([
            accountPill.heightAnchor.constraint(equalToConstant: 20),
            accountButton.leadingAnchor.constraint(equalTo: accountPill.leadingAnchor, constant: 9),
            accountButton.trailingAnchor.constraint(equalTo: accountPill.trailingAnchor, constant: -9),
            accountButton.centerYAnchor.constraint(equalTo: accountPill.centerYAnchor),
        ])
        accountPill.isHidden = true

        configureStack(leftStack, views: [modeChip, zoomChip, accountPill, cwdLabel, branchIcon, branchLabel, aheadLabel, behindLabel, changesLabel])
        leftStack.setCustomSpacing(10, after: zoomChip)
        leftStack.setCustomSpacing(10, after: cwdLabel)
        // The cwd is the one label allowed to give way: the stack may compress
        // and the path truncates (by the head) before anything else moves.
        leftStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Version pill — a bordered button (like "Open ▾") showing the build
        // version; click checks for updates.
        versionButton.isBordered = false
        versionButton.font = ZTheme.monoFont(size: 11)
        versionButton.target = self
        versionButton.action = #selector(versionClicked)
        versionButton.translatesAutoresizingMaskIntoConstraints = false
        versionPill.wantsLayer = true
        versionPill.layer?.cornerRadius = 10
        versionPill.layer?.borderWidth = 1
        versionPill.translatesAutoresizingMaskIntoConstraints = false
        versionPill.addSubview(versionButton)
        NSLayoutConstraint.activate([
            versionPill.heightAnchor.constraint(equalToConstant: 20),
            versionButton.leadingAnchor.constraint(equalTo: versionPill.leadingAnchor, constant: 9),
            versionButton.trailingAnchor.constraint(equalTo: versionPill.trailingAnchor, constant: -9),
            versionButton.centerYAnchor.constraint(equalTo: versionPill.centerYAnchor),
        ])

        // CLI pill — accent, shown only when the CLI symlink is stale/missing.
        cliButton.isBordered = false
        cliButton.font = ZTheme.monoFont(size: 11)
        cliButton.target = self
        cliButton.action = #selector(cliClicked)
        cliButton.translatesAutoresizingMaskIntoConstraints = false
        cliPill.wantsLayer = true
        cliPill.layer?.cornerRadius = 10
        cliPill.layer?.borderWidth = 1
        cliPill.translatesAutoresizingMaskIntoConstraints = false
        cliPill.isHidden = true
        cliPill.addSubview(cliButton)
        NSLayoutConstraint.activate([
            cliPill.heightAnchor.constraint(equalToConstant: 20),
            cliButton.leadingAnchor.constraint(equalTo: cliPill.leadingAnchor, constant: 9),
            cliButton.trailingAnchor.constraint(equalTo: cliPill.trailingAnchor, constant: -9),
            cliButton.centerYAnchor.constraint(equalTo: cliPill.centerYAnchor),
        ])

        configureStack(rightStack, views: [broadcastPill, cliPill, editorPill, appearanceButton, sep0, schemeDot, schemeButton, sep1, shellLabel, sep2, ghosttyLabel, sep3, versionPill])
        rightStack.setCustomSpacing(10, after: broadcastPill)
        rightStack.setCustomSpacing(10, after: cliPill)
        rightStack.setCustomSpacing(10, after: editorPill)
        rightStack.setCustomSpacing(8, after: sep3)

        addSubview(topBorder)
        addSubview(leftStack)
        addSubview(rightStack)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -12),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),

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
        let scoped = ZTheme.current.isDark ? ZColorScheme.darkSchemes : ZColorScheme.lightSchemes
        for scheme in scoped {
            let item = NSMenuItem(title: scheme.displayName,
                                  action: #selector(pickScheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scheme.rawValue
            item.state = (scheme == ZTheme.scheme) ? .on : .off
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
              let scheme = ZColorScheme(rawValue: raw) else { return }
        onSelectScheme?(scheme)
    }

    @objc private func editorClicked() {
        onShowEditorMenu?(editorPill)
    }

    @objc private func versionClicked() {
        onUpdateClicked?()
    }

    @objc private func cliClicked() {
        onCLIReinstallClicked?()
    }

    /// Shows the CLI pill when the symlink is stale/missing; hides it when the
    /// CLI matches this build.
    func setCLIStatus(_ status: CLIStatus) {
        cliStatus = status
        guard renderedCLIStatus != status else { return }
        renderedCLIStatus = status
        let theme = ZTheme.current
        switch status {
        case .current:
            cliPill.isHidden = true
        case .outdated, .notInstalled:
            cliButton.title = status == .notInstalled ? "Install CLI" : "↑ Reinstall CLI"
            cliButton.contentTintColor = theme.accentColor
            cliButton.toolTip = status == .notInstalled
                ? "The zetty CLI isn't installed — click to install"
                : "The zetty CLI points to an old build — click to reinstall"
            cliPill.layer?.backgroundColor = theme.bg3Color.cgColor
            cliPill.layer?.borderColor = theme.accentColor.cgColor
            cliPill.isHidden = false
        }
    }

    /// Sets the pending update (accent "↑ Update X" state) or clears it (back to
    /// the plain version). Re-renders the version pill.
    func setUpdate(_ update: AvailableUpdate?) {
        pendingUpdate = update
        renderVersionPill()
    }

    private func renderVersionPill() {
        let token = pendingUpdate.map { "↑\($0.version)" } ?? baseVersion
        guard renderedVersion != token else { return }
        renderedVersion = token
        let theme = ZTheme.current
        if let pendingUpdate {
            versionButton.title = "↑ Update \(pendingUpdate.version)"
            versionButton.contentTintColor = theme.accentColor
            versionButton.toolTip = "Update available — click to open the download page"
            versionPill.layer?.backgroundColor = theme.bg3Color.cgColor
            versionPill.layer?.borderColor = theme.accentColor.cgColor
        } else {
            versionButton.title = baseVersion
            versionButton.contentTintColor = theme.fg2Color
            versionButton.toolTip = "Click to check for updates"
            versionPill.layer?.backgroundColor = theme.bg2Color.cgColor
            versionPill.layer?.borderColor = theme.borderColor.cgColor
        }
    }

    // MARK: - Content

    func update(cwd: String, appearance: String, scheme: String, shell: String,
                zetty: String, ghostty: String) {
        // Every assignment is guarded: setting an unchanged `stringValue` still
        // invalidates layout, and this runs on every chrome refresh.
        if cwdLabel.stringValue != cwd { cwdLabel.stringValue = cwd }
        appearanceMode = appearance
        if shellLabel.stringValue != shell { shellLabel.stringValue = shell }
        baseVersion = zetty
        renderVersionPill()
        if ghosttyLabel.stringValue != ghostty { ghosttyLabel.stringValue = ghostty }
        styleAppearanceButton()
        styleSchemeButton(scheme)
    }

    /// Shows the key-layer mode chip: `PREFIX` while the prefix is armed,
    /// `COPY` during copy mode, hidden in normal mode.
    func setKeyMode(_ mode: KeyMode) {
        switch mode {
        case .normal:
            modeChip.isHidden = true
        case .prefixArmed:
            modeChip.stringValue = " PREFIX "
            modeChip.isHidden = false
        case .copyMode:
            modeChip.stringValue = " COPY "
            modeChip.isHidden = false
        }
        styleChips()
    }

    /// Shows/hides the `ZOOM` chip (a pane is temporarily maximized).
    func setZoomed(_ zoomed: Bool) {
        guard zoomChip.isHidden != !zoomed else { return }
        zoomChip.isHidden = !zoomed
        styleChips()
    }

    /// Updates the broadcast pill to reflect the active scope.
    func setBroadcasting(_ scope: BroadcastScope) {
        shownBroadcastScope = scope
        renderBroadcastPill()
    }

    @objc private func broadcastClicked() { onBroadcastClicked?() }

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
        // Same inputs, different colors — the renderers below must not no-op.
        invalidateRenderCaches()
        let theme = ZTheme.current
        layer?.backgroundColor = theme.bg0Color.cgColor
        topBorder.layer?.backgroundColor = theme.borderColor.cgColor
        schemeDot.layer?.backgroundColor = theme.accentColor.cgColor
        branchIcon.contentTintColor = theme.purpleColor

        let font = ZTheme.monoFont(size: 11)
        for label in plainLabels { label.font = font }

        cwdLabel.textColor = theme.fg2Color
        branchLabel.textColor = theme.purpleColor
        aheadLabel.textColor = theme.greenColor
        behindLabel.textColor = theme.redColor
        changesLabel.textColor = theme.yellowColor
        shellLabel.textColor = theme.fg2Color
        renderVersionPill()
        setCLIStatus(cliStatus)
        ghosttyLabel.textColor = theme.fg2Color
        sep0.textColor = theme.fg3Color
        sep1.textColor = theme.fg3Color
        sep2.textColor = theme.fg3Color
        sep3.textColor = theme.fg3Color
        editorPill.layer?.backgroundColor = theme.bg2Color.cgColor
        editorPill.layer?.borderColor = theme.borderColor.cgColor
        editorButton.contentTintColor = theme.fg2Color
        editorButton.attributedTitle = NSAttributedString(
            string: "Open ",
            attributes: [
                .font: ZTheme.monoFont(size: 11, weight: .medium),
                .foregroundColor: theme.fgColor,
            ]
        )
        editorButton.toolTip = "Open the focused pane's directory in an editor or Finder"

        styleAppearanceButton()
        styleSchemeButton(schemeButton.title)
        styleChips()
    }

    /// Chips are bg3 pills with accent text and a soft accent glow (design
    /// rules 3/9: accent marks the active mode and glows; fills stay surfaces).
    private func styleChips() {
        let theme = ZTheme.current
        for chip in [modeChip, zoomChip] {
            chip.font = ZTheme.monoFont(size: 10, weight: .semibold)
            chip.textColor = theme.accentColor
            chip.layer?.backgroundColor = theme.bg3Color.cgColor
            guard !chip.isHidden else {
                chip.layer?.shadowOpacity = 0
                continue
            }
            chip.layer?.shadowColor = theme.accentColor.cgColor
            chip.layer?.shadowOpacity = 0.45
            chip.layer?.shadowRadius = 5
            chip.layer?.shadowOffset = .zero
        }

        renderBroadcastPill()
    }

    /// The broadcast pill: antenna icon + scope (OFF / TAB / PROJECT / AGENTS /
    /// WORKSPACE), no "BROADCAST" word. Neutral (bg2) when Off; when active it's
    /// a yellow-glowing warning — broadcast is "dangerous" (every keystroke hits
    /// N shells), so it uses the attention token, not the accent (DESIGN.md
    /// rule-3 deviation). Rebuilt on scope + theme change.
    private func renderBroadcastPill() {
        guard renderedBroadcastScope != shownBroadcastScope else { return }
        renderedBroadcastScope = shownBroadcastScope
        let active = shownBroadcastScope.isActive
        let label: String
        switch shownBroadcastScope {
        case .off:        label = "OFF"
        case .currentTab: label = "TAB"
        case .project:    label = "PROJECT"
        case .agents:     label = "AGENTS"
        case .workspace:  label = "WORKSPACE"
        }
        let theme = ZTheme.current
        let tint = active ? theme.yellowColor : theme.fg3Color
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        broadcastButton.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                                        accessibilityDescription: "Broadcast")?
            .withSymbolConfiguration(symbolConfig)
        broadcastButton.contentTintColor = tint
        broadcastButton.attributedTitle = NSAttributedString(
            string: " \(label)",
            attributes: [
                .font: ZTheme.monoFont(size: 10, weight: .semibold),
                .foregroundColor: tint,
            ])
        broadcastButton.toolTip = "Broadcast input — click to cycle scope (⇧⌘B)"
        broadcastPill.layer?.backgroundColor = (active ? theme.bg3Color : theme.bg2Color).cgColor
        broadcastPill.layer?.borderColor = (active ? theme.yellowColor : theme.borderColor).cgColor
        broadcastPill.layer?.shadowColor = theme.yellowColor.cgColor
        broadcastPill.layer?.shadowOpacity = active ? 0.4 : 0
        broadcastPill.layer?.shadowRadius = 5
    }

    /// The focused pane's account. `nil` (or the default account with no
    /// accounts configured) hides the chip.
    func setAccount(_ resolution: AccountResolution?, hasAccounts: Bool) {
        shownAccount = hasAccounts ? resolution : nil
        renderAccountPill()
    }

    /// Follows `renderBroadcastPill`'s cached-token shape: `attributedTitle` is
    /// assigned only inside the guard, so the KVO leak stays bounded to real
    /// changes rather than every refresh tick.
    private func renderAccountPill() {
        let token = shownAccount.map {
            "\($0.accountID)|\($0.colorID ?? "")|\($0.agentID ?? "")"
        } ?? ""
        guard renderedAccountToken != token else { return }
        renderedAccountToken = token

        guard let account = shownAccount else {
            accountPill.isHidden = true
            return
        }
        accountPill.isHidden = false
        let theme = ZTheme.current
        // The account's own palette hue, never the accent — accent is reserved
        // for focus/active/brand, and identity-by-hue is the projectPalette's job.
        let tint = ZTheme.projectColor(id: account.colorID) ?? theme.fg3Color
        accountButton.image = NSImage(systemSymbolName: "person.crop.circle",
                                      accessibilityDescription: "Account")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        accountButton.contentTintColor = tint
        // "Default" or "<Account> (<Agent>)" — the harness is named in text
        // rather than shown as a logo. The default login isn't tied to one
        // harness, so it carries no suffix.
        let agentName = account.agentID.flatMap { SpawnableAgent.byID($0)?.shortName }
        let label = agentName.map { "\(account.displayName) (\($0))" } ?? account.displayName
        accountButton.attributedTitle = NSAttributedString(
            string: " \(label)",
            attributes: [
                .font: ZTheme.monoFont(size: 10, weight: .semibold),
                .foregroundColor: tint,
            ])
        accountButton.toolTip = account.isDefault
            ? "This pane uses your default login — click to manage accounts"
            : "This pane runs as \(account.displayName) — click to manage accounts"
        accountPill.layer?.backgroundColor =
            (account.isDefault ? theme.bg2Color : theme.bg3Color).cgColor
        accountPill.layer?.borderColor =
            (account.isDefault ? theme.borderColor : tint).cgColor
    }

    @objc private func accountClicked() { onAccountClicked?() }

    private func styleAppearanceButton() {
        guard renderedAppearance != appearanceMode else { return }
        renderedAppearance = appearanceMode
        let icon: String
        switch appearanceMode.lowercased() {
        case "dark":  icon = "moon.fill"
        case "light": icon = "sun.max.fill"
        default:      icon = "circle.lefthalf.filled"
        }
        appearanceButton.image = NSImage(systemSymbolName: icon, accessibilityDescription: appearanceMode)
        appearanceButton.contentTintColor = ZTheme.current.fg2Color
        appearanceButton.attributedTitle = NSAttributedString(
            string: " \(appearanceMode)",
            attributes: [
                .font: ZTheme.monoFont(size: 11),
                .foregroundColor: ZTheme.current.fg2Color,
            ]
        )
        appearanceButton.toolTip = "Appearance: \(appearanceMode) — click to cycle"
    }

    private func styleSchemeButton(_ name: String) {
        guard renderedScheme != name else { return }
        renderedScheme = name
        schemeButton.attributedTitle = NSAttributedString(
            string: name,
            attributes: [
                .font: ZTheme.monoFont(size: 11),
                .foregroundColor: ZTheme.current.accentColor,
            ]
        )
        schemeButton.toolTip = "Color scheme: \(name) — click to cycle (⇧⌘T)"
    }
}
