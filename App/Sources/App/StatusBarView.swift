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
    /// The same picker as a detached menu, so the compact bar can hang it off
    /// the `⋯` menu as a submenu rather than popping a second menu.
    var onBuildEditorMenu: (() -> NSMenu)?

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
    /// The git views as one unit, so they fold away together.
    private let gitStack = NSStackView()
    /// The compact stand-in for the WHOLE left cluster — directory, branch and
    /// a dirty dot in one pill, click for the full path and the counts.
    private let locationChip = NSView()
    private let locationChipLabel = NSTextField(labelWithString: "")
    private let locationChipChevron = NSImageView()
    private let leftStack = NSStackView()

    /// Whether the cwd and git have folded into `locationChip`. Unlike
    /// `isCompact` this is about legibility, not the window floor — see
    /// `LocationChip`.
    private var isLocationCollapsed = false
    private var shownGit: GitStatus = .none
    /// The cwd as displayed, mirrored so the chip and its dropup can render
    /// without reading it back off a label that may be hidden.
    private var shownCwd = ""

    /// `gitStack.fittingSize.width` remembered across passes, for the same
    /// reason `cachedInfoWidth` is: hidden measures zero, and zero reads as
    /// "it fits".
    private var cachedGitWidth: CGFloat = 0
    private var renderedLocationChipToken: String?

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

    // The right side is three pieces, and the split is load-bearing rather
    // than cosmetic — see `layout()`. `pillStack` (the action controls) is the
    // only one pinned to the trailing edge and the only one whose width reaches
    // `fittingSize`; `infoStack` (the ambient stats) is frame-positioned inside
    // `infoHost`, which claims the leftover space but is never sized by its
    // contents; `infoChip` stands in for the whole ambient group when that
    // leftover runs out.
    private let infoStack = NSStackView()
    private let infoHost = NSView()
    private let pillStack = NSStackView()

    /// The compact stand-in for `infoStack`: the colour scheme (dot + name, as
    /// the wide bar renders it), clicked to open all the ambient stats.
    ///
    /// It shows the scheme rather than rotating through the stats, and the
    /// distinction matters. `pillStack` hugs its content, so anything that
    /// changes width in here resizes the stack and drags its neighbours
    /// sideways — an earlier version rotated every 4s and moved `Open ▾` out
    /// from under the pointer mid-click. A scheme name changes only when
    /// someone changes the scheme, and by then `Open ▾` and the account have
    /// folded away, so in the ordinary compact bar this pill is the only thing
    /// in the stack and nothing can shift. Do not reintroduce anything that
    /// changes width on a timer.
    private let infoChip = NSView()
    private let infoChipLabel = NSTextField(labelWithString: "")
    private let infoChipGlyph = NSImageView()
    private let infoChipChevron = NSImageView()

    private var appearanceMode = "System"

    // MARK: - Compact mode

    /// The ambient stats' current values, mirrored from `update(...)` so the
    /// chip and its menu can render without re-reading the views.
    private var infoValues = StatusInfoValues()
    /// Whether `infoStack` has folded into `infoChip`. Flipped only by
    /// `layout()`, through `StatusBarCompaction`'s hysteresis.
    private var isCompact = false
    /// `infoStack.fittingSize.width`, remembered across passes. A hidden stack
    /// can measure zero, and a zero requirement would read as "it fits" and
    /// bounce the bar straight back to wide.
    private var cachedInfoWidth: CGFloat = 0
    /// One baseline measurement per window, so the floor is on record even
    /// when nobody ever drags the window narrow enough to flip the mode.
    private var didLogFloor = false

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
    /// Cached by the chip's rendered text plus its mode, so the 4s rotation
    /// repaints but an unchanged refresh tick does not.
    private var renderedChipToken: String?

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
        renderedChipToken = nil
        renderedLocationChipToken = nil
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
        // A branch name is unbounded, and with the default (required)
        // resistance a long one silently raises the window's minimum width —
        // `.byTruncatingTail` alone never gets the chance to fire.
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        // The git chip, built like its right-hand counterpart: an NSTextField
        // for the text (never a button's `attributedTitle`, which leaks a KVO
        // record per assignment and this one re-renders on every git probe),
        // and a gesture recognizer for the click.
        locationChip.wantsLayer = true
        locationChip.layer?.cornerRadius = 10
        locationChip.layer?.borderWidth = 1
        locationChip.translatesAutoresizingMaskIntoConstraints = false
        locationChip.isHidden = true
        locationChipLabel.lineBreakMode = .byTruncatingTail
        locationChipLabel.translatesAutoresizingMaskIntoConstraints = false
        locationChipLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationChipChevron.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            locationChipChevron.image = NSImage(systemSymbolName: "chevron.up",
                                           accessibilityDescription: "Show git details")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
            locationChipChevron.imageScaling = .scaleProportionallyDown
        }
        locationChip.addSubview(locationChipLabel)
        locationChip.addSubview(locationChipChevron)
        locationChip.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(locationChipClicked)))
        NSLayoutConstraint.activate([
            locationChip.heightAnchor.constraint(equalToConstant: 20),
            locationChipLabel.leadingAnchor.constraint(equalTo: locationChip.leadingAnchor, constant: 9),
            locationChipLabel.centerYAnchor.constraint(equalTo: locationChip.centerYAnchor),
            locationChipChevron.leadingAnchor.constraint(equalTo: locationChipLabel.trailingAnchor, constant: 5),
            locationChipChevron.trailingAnchor.constraint(equalTo: locationChip.trailingAnchor, constant: -8),
            locationChipChevron.centerYAnchor.constraint(equalTo: locationChip.centerYAnchor),
            locationChipChevron.widthAnchor.constraint(equalToConstant: 8),
        ])

        configureStack(gitStack, views: [branchIcon, branchLabel, aheadLabel, behindLabel, changesLabel])
        gitStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureStack(leftStack, views: [modeChip, zoomChip, accountPill, cwdLabel, gitStack, locationChip])
        leftStack.setCustomSpacing(10, after: zoomChip)
        leftStack.setCustomSpacing(10, after: cwdLabel)
        // The cwd is the one label allowed to give way FIRST: the path
        // truncates (by the head) before anything else moves.
        leftStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // But lowering it on the STACK is not enough, and assuming otherwise
        // is what left the measured floor at 477pt. A stack pins its arranged
        // subviews to its edges at required priority, so any child that
        // resists compression holds the whole stack — and the window — open,
        // whatever the stack's own resistance says. The account pill was the
        // worst of them: its width follows an account name nobody bounded.
        for squeezable in [accountPill, modeChip, zoomChip, aheadLabel,
                           behindLabel, changesLabel] as [NSView] {
            squeezable.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        accountButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        broadcastButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

        // The compact chip: a scheme dot, the scheme name, and a chevron — the
        // same anatomy as the location pill on the other side.
        //
        // The text is an NSTextField, never a button's `attributedTitle`: that
        // setter leaks a KVO dependency record per assignment. The click comes
        // from a gesture recognizer on the pill.
        infoChip.wantsLayer = true
        infoChip.layer?.cornerRadius = 10
        infoChip.layer?.borderWidth = 1
        infoChip.translatesAutoresizingMaskIntoConstraints = false
        infoChip.isHidden = true
        infoChipLabel.lineBreakMode = .byTruncatingTail
        infoChipLabel.translatesAutoresizingMaskIntoConstraints = false
        // The chip gives way before anything else, so its content can never be
        // what holds the window open.
        infoChipLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoChipGlyph.translatesAutoresizingMaskIntoConstraints = false
        infoChipGlyph.imageScaling = .scaleProportionallyDown
        infoChipChevron.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            infoChipChevron.image = NSImage(systemSymbolName: "chevron.up",
                                            accessibilityDescription: "Show all status details")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
            infoChipChevron.imageScaling = .scaleProportionallyDown
        }
        infoChip.addSubview(infoChipGlyph)
        infoChip.addSubview(infoChipLabel)
        infoChip.addSubview(infoChipChevron)
        infoChip.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(infoChipClicked)))
        NSLayoutConstraint.activate([
            infoChip.heightAnchor.constraint(equalToConstant: 20),
            infoChipGlyph.leadingAnchor.constraint(equalTo: infoChip.leadingAnchor, constant: 9),
            infoChipGlyph.centerYAnchor.constraint(equalTo: infoChip.centerYAnchor),
            infoChipGlyph.widthAnchor.constraint(equalToConstant: 8),
            infoChipGlyph.heightAnchor.constraint(equalToConstant: 8),
            infoChipLabel.leadingAnchor.constraint(equalTo: infoChipGlyph.trailingAnchor, constant: 6),
            infoChipLabel.centerYAnchor.constraint(equalTo: infoChip.centerYAnchor),
            infoChipChevron.leadingAnchor.constraint(equalTo: infoChipLabel.trailingAnchor, constant: 5),
            infoChipChevron.trailingAnchor.constraint(equalTo: infoChip.trailingAnchor, constant: -8),
            infoChipChevron.centerYAnchor.constraint(equalTo: infoChip.centerYAnchor),
            infoChipChevron.widthAnchor.constraint(equalToConstant: 8),
        ])

        // Ambient stats. Frame-positioned inside `infoHost`, so this stack is
        // deliberately NOT given `translatesAutoresizingMaskIntoConstraints =
        // false` the way every other stack here is.
        configureStack(infoStack, views: [appearanceButton, sep0, schemeDot, schemeButton,
                                          sep1, shellLabel, sep2, ghosttyLabel, sep3, versionPill])
        infoStack.setCustomSpacing(8, after: sep3)
        infoStack.translatesAutoresizingMaskIntoConstraints = true

        infoHost.wantsLayer = true
        infoHost.layer?.masksToBounds = true
        infoHost.translatesAutoresizingMaskIntoConstraints = false
        infoHost.addSubview(infoStack)

        // Action controls — the only part of the right side pinned to the
        // trailing edge, and the only part whose width AppKit may turn into a
        // window minimum.
        configureStack(pillStack, views: [broadcastPill, cliPill, editorPill, infoChip])
        pillStack.setCustomSpacing(10, after: broadcastPill)
        pillStack.setCustomSpacing(10, after: cliPill)
        pillStack.setCustomSpacing(10, after: editorPill)

        addSubview(topBorder)
        addSubview(leftStack)
        addSubview(infoHost)
        addSubview(pillStack)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            pillStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pillStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            infoHost.trailingAnchor.constraint(equalTo: pillStack.leadingAnchor, constant: -10),
            infoHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoHost.heightAnchor.constraint(equalToConstant: 20),

            branchIcon.widthAnchor.constraint(equalToConstant: 11),
            branchIcon.heightAnchor.constraint(equalToConstant: 11),
            schemeDot.widthAnchor.constraint(equalToConstant: 7),
            schemeDot.heightAnchor.constraint(equalToConstant: 7),
        ])

        // `infoHost` takes whatever is left between the two clusters, and
        // NOTHING ties its width to the stack inside it. That is the whole
        // reason the window can reach 320pt: an ambient group measured by Auto
        // Layout would reach `fittingSize`, which is where AppKit derives the
        // window's minimum content width from — the same trap the tab strip
        // documents at length. Hiding the group on resize cannot substitute,
        // because the window could never shrink far enough to trigger it.
        //
        // The pair below is a "fill the gap, but never overlap": priority 1
        // pulls the host left across the leftover, 999 stops it reaching the
        // left cluster. 999 rather than required so an extreme squeeze degrades
        // into an overlap (the host is empty by then) instead of an
        // unsatisfiable layout.
        let hostFill = infoHost.leadingAnchor.constraint(equalTo: leftStack.trailingAnchor, constant: 12)
        hostFill.priority = NSLayoutConstraint.Priority(1)
        let hostClear = infoHost.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor,
                                                          constant: 12)
        hostClear.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([hostFill, hostClear])

        updateGit(.none)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // MARK: - Compact layout
    //
    // Verify a change in here by measuring, not by eye: log
    // `window.contentView?.fittingSize.width` while dragging the window narrow
    // and while adding tabs. It must stay flat and below `minimumContentSize`.

    override func layout() {
        super.layout()

        // Measured only to SIZE the frame-positioned stack, never to decide
        // the layout. A stack reports zero while hidden, so the last real
        // measurement stands in.
        let measured = infoStack.fittingSize.width
        if measured > 0 { cachedInfoWidth = measured }

        // The decision is the WINDOW's width. Deciding from leftover space
        // meant the threshold moved every time an agent ran `cd`, because the
        // left cluster holds the very path being measured against — so the bar
        // flapped between layouts while nothing was being resized.
        let windowWidth = Double(bounds.width)
        let compact = StatusBarCompaction.isCompact(windowWidth: windowWidth,
                                                    wasCompact: isCompact)
        let flipped = compact != isCompact
        if flipped {
            isCompact = compact
            applyCompactState()
        }

        // `fittingSize` is what AppKit turns into the window's minimum content
        // width, so this line is the check: it must stay under
        // `AppDelegate.minimumContentSize` in BOTH modes. Because the ambient
        // group is frame-positioned rather than constrained, the wide reading
        // answers it too — which is what makes the floor verifiable without
        // dragging the window. If a report says the window won't shrink, read
        // this back first.
        if flipped || !didLogFloor, let content = window?.contentView {
            didLogFloor = true
            ZettyLog.chrome.log("statusbar: compact=\(compact) width=\(Int(windowWidth)) "
                + "threshold=\(Int(StatusBarCompaction.compactBelow)) "
                + "pills=\(Int(pillStack.fittingSize.width)) "
                + "bar=\(Int(fittingSize.width)) "
                + "content=\(Int(content.fittingSize.width))")
        }

        layoutLocationCluster()

        // The stack is frame-positioned so its width never reaches a
        // constraint. Right-aligned, so the ambient stats stay adjacent to the
        // controls they sit beside.
        let size = NSSize(width: cachedInfoWidth, height: infoHost.bounds.height)
        infoStack.frame = NSRect(x: infoHost.bounds.width - size.width, y: 0,
                                 width: size.width, height: size.height)
    }

    /// Folds the working directory AND git into `locationChip` when keeping
    /// them expanded would leave the path unreadable, and back again once
    /// there is room.
    ///
    /// Driven by the window's width. Measuring leftover space meant the
    /// threshold moved every time an agent ran `cd` — the path being measured
    /// is part of what it was measured against.
    private func layoutLocationCluster() {
        let measured = gitStack.fittingSize.width
        if measured > 0 { cachedGitWidth = measured }

        let collapse = LocationChip.shouldCollapse(windowWidth: Double(bounds.width),
                                                   wasCollapsed: isLocationCollapsed)
        guard collapse != isLocationCollapsed else { return }
        isLocationCollapsed = collapse
        applyLocationCollapse()
    }

    private func applyLocationCollapse() {
        let text = LocationChip.label(cwd: shownCwd, git: shownGit)
        let showChip = isLocationCollapsed && !text.isEmpty
        // `updateGit` calls this on every git probe — cwd changes plus a 15s
        // timer — so the log has to be guarded by a real state change or it
        // becomes a heartbeat rather than a signal.
        let changed = gitStack.isHidden != isLocationCollapsed
            || locationChip.isHidden == showChip
        // The cwd folds in WITH git now: one pill for the whole cluster rather
        // than a truncated path sitting beside a chip.
        cwdLabel.isHidden = showChip
        gitStack.isHidden = isLocationCollapsed
        locationChip.isHidden = !showChip
        renderLocationChip()
        if changed {
            ZettyLog.chrome.log("location: collapsed=\(isLocationCollapsed) chip=\(showChip) "
                + "width=\(Int(bounds.width)) "
                + "threshold=\(Int(StatusBarCompaction.collapseLeftBelow))")
        }
    }

    private func renderLocationChip() {
        guard !locationChip.isHidden else { return }
        let text = LocationChip.label(cwd: shownCwd, git: shownGit)
        guard renderedLocationChipToken != text else { return }
        renderedLocationChipToken = text

        let theme = ZTheme.current
        locationChipLabel.stringValue = text
        locationChipLabel.font = ZTheme.monoFont(size: 11)
        // Purple stays git's semantic colour whether expanded or folded; the
        // directory half rides along rather than getting a second hue.
        locationChipLabel.textColor = shownGit.isRepo ? theme.purpleColor : theme.fg2Color
        locationChipChevron.contentTintColor = theme.fg3Color
        locationChip.layer?.backgroundColor = theme.bg2Color.cgColor
        locationChip.layer?.borderColor = theme.borderColor.cgColor
        locationChip.toolTip = "Working directory and git — click for the full path and counts"
    }

    /// The left cluster's dropup: the full working directory and the git state,
    /// neither of which survives the truncation that made the chip necessary.
    /// Display only — the status bar has never acted on either.
    @objc private func locationChipClicked() {
        let lines = LocationChip.detailLines(cwd: shownCwd, git: shownGit)
        let account = shownAccount.map(accountDisplayName)
        guard !lines.isEmpty || account != nil else { return }

        let menu = NSMenu()
        if let first = lines.first {
            menu.addItem(withTitle: first, action: nil, keyEquivalent: "")
        }
        if lines.count > 1 {
            menu.addItem(.separator())
            for line in lines.dropFirst() {
                menu.addItem(withTitle: line, action: nil, keyEquivalent: "")
            }
        }
        if let account {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Account: \(account)",
                                  action: #selector(accountClicked), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        popUp(menu, from: locationChip)
    }

    /// Swaps the ambient group for the chip (or back) and re-renders the two
    /// pills that carry a label only when there is room for one.
    private func applyCompactState() {
        infoStack.isHidden = isCompact
        infoChip.isHidden = !isCompact
        // Compact is two pills, and everything else earns its place by being
        // in a state that would be wrong to hide. `Open ▾` never is — it is a
        // menu, and folding a menu into a menu costs one click and loses
        // nothing — so it always folds.
        editorPill.isHidden = isCompact
        // Same inputs, different labels — the cached renderers would no-op.
        renderedBroadcastScope = nil
        renderedChipToken = nil
        updateBroadcastVisibility()
        renderBroadcastPill()
        updateAccountVisibility()
        styleEditorButton()
        renderInfoChip()
    }

    /// Broadcast is the one control that must not fold away silently: while it
    /// is active every keystroke reaches N shells, which is why it is the only
    /// pill that glows. So it folds when the scope is OFF — the overwhelmingly
    /// common case, and the one where hiding it costs nothing — and breaks back
    /// out, label and all, the moment it is armed.
    private func updateBroadcastVisibility() {
        broadcastPill.isHidden = isCompact && !shownBroadcastScope.isActive
    }

    /// The account folds into the location pill's dropup. It is identity rather
    /// than state, and it is not the only place it shows — the tab pill carries
    /// an account dot too, so a compact bar is not the last word on it.
    private func updateAccountVisibility() {
        accountPill.isHidden = isCompact || shownAccount == nil
    }

    private func renderInfoChip() {
        guard isCompact else { return }
        let theme = ZTheme.current
        let update = pendingUpdate
        // An update takes the chip over: it is the one item here worth acting
        // on, and a menu is no place for a call to action.
        let text = update.map { "Update \($0.version)" }
            ?? infoValues.label(for: .scheme)
        let token = "\(update != nil)|\(text)"
        guard renderedChipToken != token else { return }
        renderedChipToken = token

        let tint = update != nil ? theme.accentColor : theme.fg2Color
        infoChipLabel.stringValue = text
        infoChipLabel.font = ZTheme.monoFont(size: 11)
        infoChipLabel.textColor = tint
        // Accent, matching `schemeDot` in the wide bar — the scheme is brand,
        // which is one of the three things accent is for.
        if #available(macOS 11.0, *) {
            let symbol = update != nil ? "arrow.up.circle.fill" : "circle.fill"
            infoChipGlyph.image = NSImage(systemSymbolName: symbol,
                                          accessibilityDescription: "Status details")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        }
        infoChipGlyph.contentTintColor = theme.accentColor
        infoChipChevron.contentTintColor = theme.fg3Color
        infoChipChevron.isHidden = update != nil
        infoChip.layer?.backgroundColor = (update != nil ? theme.bg3Color : theme.bg2Color).cgColor
        infoChip.layer?.borderColor = (update != nil ? theme.accentColor : theme.borderColor).cgColor
        infoChip.toolTip = update != nil
            ? "Update available — click to open the download page"
            : "Appearance, scheme, shell, libghostty and version — click for all of them"
    }

    /// With an update pending the chip IS the update button; otherwise it opens
    /// every ambient stat at once, each one still carrying the action its wide
    /// counterpart had. The menu is where the readout lives now that the chip
    /// itself has to hold a constant width.
    @objc private func infoChipClicked() {
        if pendingUpdate != nil {
            onUpdateClicked?()
            return
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "")
            .submenu = appearanceMenu()
        menu.addItem(withTitle: "Color Scheme", action: nil, keyEquivalent: "")
            .submenu = schemeMenu()

        // The two controls that folded away. Each keeps the behaviour its pill
        // had — broadcast cycles, Open opens its own picker — rather than
        // growing a second way to do the same thing.
        let broadcast = NSMenuItem(title: "Broadcast: \(shownBroadcastScope.displayLabel)",
                                   action: #selector(broadcastClicked), keyEquivalent: "")
        broadcast.target = self
        menu.addItem(broadcast)

        // A submenu, not a second popup: every other entry here opens sideways,
        // and an item that closes this menu to open one of its own reads as a
        // different kind of control.
        if let editors = onBuildEditorMenu?() {
            menu.addItem(withTitle: "Open Directory In", action: nil, keyEquivalent: "")
                .submenu = editors
        }

        menu.addItem(.separator())
        for item in [StatusInfoItem.shell, .ghostty] where !infoValues.label(for: item).isEmpty {
            menu.addItem(withTitle: infoValues.label(for: item), action: nil, keyEquivalent: "")
        }
        let version = NSMenuItem(title: infoValues.label(for: .version).isEmpty
                                     ? "Check for Updates"
                                     : "\(infoValues.label(for: .version)) — Check for Updates",
                                 action: #selector(versionClicked), keyEquivalent: "")
        version.target = self
        menu.addItem(version)

        popUp(menu, from: infoChip)
    }

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
        popUp(appearanceMenu(), from: appearanceButton)
    }

    private func appearanceMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in [AppearanceMode.system, .dark, .light] {
            let item = NSMenuItem(title: mode.rawValue.capitalized,
                                  action: #selector(pickAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode.rawValue.capitalized == appearanceMode) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// Pops up a scheme picker for the current axis above the button.
    @objc private func schemeClicked() {
        popUp(schemeMenu(), from: schemeButton)
    }

    private func schemeMenu() -> NSMenu {
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
        return menu
    }

    private func popUp(_ menu: NSMenu, from view: NSView) {
        // Anchor above the view (status bar sits at the window bottom).
        let point = NSPoint(x: 0, y: -6)
        menu.popUp(positioning: nil, at: point, in: view)
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
        renderInfoChip()
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
        if shownCwd != cwd {
            shownCwd = cwd
            applyLocationCollapse()
        }
        appearanceMode = appearance
        if shellLabel.stringValue != shell { shellLabel.stringValue = shell }
        baseVersion = zetty
        renderVersionPill()
        if ghosttyLabel.stringValue != ghostty { ghosttyLabel.stringValue = ghostty }
        styleAppearanceButton()
        styleSchemeButton(scheme)

        let values = StatusInfoValues(appearance: appearance, scheme: scheme, shell: shell,
                                      ghostty: ghostty, version: zetty)
        guard values != infoValues else { return }
        infoValues = values
        renderInfoChip()
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
        updateBroadcastVisibility()
    }

    @objc private func broadcastClicked() { onBroadcastClicked?() }

    func updateGit(_ status: GitStatus) {
        shownGit = status
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

        // No special case for leaving a repo: the chip carries the directory
        // too, so it stays valid — `LocationChip.label` simply drops the branch
        // half. Re-rendering here is what stops a stale branch name persisting.
        applyLocationCollapse()
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
        styleEditorButton()

        styleAppearanceButton()
        styleSchemeButton(schemeButton.title)
        styleChips()
        renderInfoChip()
        renderLocationChip()
    }

    /// "Open ▾", or just the chevron once the bar is compact — at that width
    /// every label the bar can drop is one the terminal gets back.
    private func styleEditorButton() {
        let theme = ZTheme.current
        editorPill.layer?.backgroundColor = theme.bg2Color.cgColor
        editorPill.layer?.borderColor = theme.borderColor.cgColor
        editorButton.contentTintColor = theme.fg2Color
        editorButton.attributedTitle = NSAttributedString(
            string: isCompact ? "" : "Open ",
            attributes: [
                .font: ZTheme.monoFont(size: 11, weight: .medium),
                .foregroundColor: theme.fgColor,
            ]
        )
        editorButton.toolTip = "Open the focused pane's directory in an editor or Finder"
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
        let label = shownBroadcastScope.displayLabel
        let theme = ZTheme.current
        let tint = active ? theme.yellowColor : theme.fg3Color
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        broadcastButton.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                                        accessibilityDescription: "Broadcast")?
            .withSymbolConfiguration(symbolConfig)
        broadcastButton.contentTintColor = tint
        // The scope stays spelled out even when compact. The pill is only on
        // screen at all in the state where it is armed, and "broadcasting, but
        // you'd have to hover to learn where" is the worst of both.
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
            updateAccountVisibility()
            return
        }
        updateAccountVisibility()
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
        let label = accountDisplayName(account)
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

    /// "Default", or "<Account> (<Agent>)". The harness is named in text rather
    /// than shown as a logo; the default login isn't tied to one, so it carries
    /// no suffix.
    private func accountDisplayName(_ account: AccountResolution) -> String {
        let agent = account.agentID.flatMap { SpawnableAgent.byID($0)?.shortName }
        return agent.map { "\(account.displayName) (\($0))" } ?? account.displayName
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
