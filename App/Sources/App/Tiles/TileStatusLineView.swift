import AppKit
import ZettyCore

/// A tile's own status line — the status bar's account · cwd · git cluster
/// for the pane this tile shows. Tile mode hides that cluster from the bar
/// (`StatusBarView.updateLocationVisibility`), so this is where it lives.
///
/// Mono, deliberately: it IS the status bar, per tile, and must read as the
/// line that just left the bottom of the window. Design rule 2's mono
/// exception covers it.
///
/// Labels are frame-laid in `layout()` from `TileStatusLine.visibleParts`, so
/// parts drop whole in the ladder's order and nothing here can constrain the
/// tile's size — the grid frame-positions tiles for the same reason.
///
/// Clicks: `hitTest` answers with the account chip or with this view, never a
/// label, so a click lands somewhere defined. The chip consumes its own; a
/// single click anywhere else reaches `TileView.mouseDown` and focuses the
/// tile. A double-click is swallowed — on a tile it means "leave the grid",
/// which belongs to the header, not to a strip you might click twice to read.
@MainActor
final class TileStatusLineView: NSView {

    static let height = CGFloat(TileStatusLine.footerHeight)
    private static let accountIconWidth: CGFloat = 16
    private static let accountIconSize: CGFloat = 10
    private static let accountPillHeight: CGFloat = 14

    var onAccountClicked: (() -> Void)?

    private let topBorder = NSView()
    /// An icon and a plain label inside a click view, not an `NSButton`: the
    /// label's width is then exactly what the ladder measured (a button adds
    /// insets of its own), and there is no `attributedTitle` to leak KVO.
    private let accountPill = ClickRowView()
    private let accountIcon = NSImageView()
    private let accountLabel = NSTextField(labelWithString: "")
    private let cwdLabel = NSTextField(labelWithString: "")
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let aheadLabel = NSTextField(labelWithString: "")
    private let behindLabel = NSTextField(labelWithString: "")
    private let changesLabel = NSTextField(labelWithString: "")

    private var line: TileStatusLine?
    /// Last line actually rendered; nil forces the next `setLine` through.
    /// `applyTheme` clears it — the input is equal, only the colours moved.
    private var renderedLine: TileStatusLine?
    /// The account the chip was last styled for (id, colour, harness,
    /// default-ness), so a cwd or git change leaves the chip alone. nil forces
    /// a restyle — `applyTheme` clears it.
    private var chipToken: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        topBorder.wantsLayer = true
        accountPill.wantsLayer = true
        accountPill.layer?.cornerRadius = 4
        accountPill.layer?.borderWidth = 1
        accountPill.onClick = { [weak self] in self?.onAccountClicked?() }
        accountIcon.imageScaling = .scaleProportionallyDown
        accountLabel.font = ZTheme.monoFont(size: 9, weight: .semibold)
        accountPill.addSubview(accountIcon)
        accountPill.addSubview(accountLabel)
        cwdLabel.lineBreakMode = .byTruncatingHead
        branchLabel.lineBreakMode = .byTruncatingTail
        branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch",
                                   accessibilityDescription: "Git branch")
        branchIcon.imageScaling = .scaleProportionallyDown
        for label in [cwdLabel, branchLabel, aheadLabel, behindLabel, changesLabel] {
            label.font = ZTheme.monoFont(size: 10)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view: NSView in [topBorder, accountPill, cwdLabel, branchIcon, branchLabel,
                             aheadLabel, behindLabel, changesLabel] {
            addSubview(view)
        }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func setLine(_ newLine: TileStatusLine?) {
        guard newLine != renderedLine else { return }
        line = newLine
        renderedLine = newLine
        render()
        needsLayout = true
    }

    func applyTheme() {
        let theme = ZTheme.current
        layer?.backgroundColor = theme.bg0Color.cgColor
        topBorder.layer?.backgroundColor = theme.borderColor.cgColor
        cwdLabel.textColor = theme.fg2Color
        branchIcon.contentTintColor = theme.purpleColor
        branchLabel.textColor = theme.purpleColor
        aheadLabel.textColor = theme.greenColor
        behindLabel.textColor = theme.redColor
        changesLabel.textColor = theme.yellowColor
        renderedLine = nil
        chipToken = nil
        setLine(line)
    }

    private func render() {
        guard let line else {
            // Nothing to describe: no stale path or counts left in a tooltip.
            toolTip = nil
            accountPill.toolTip = nil
            chipToken = nil
            return
        }
        cwdLabel.stringValue = line.cwd
        branchLabel.stringValue = line.git.branch
        aheadLabel.stringValue = line.git.ahead > 0 ? "↑\(line.git.ahead)" : ""
        behindLabel.stringValue = line.git.behind > 0 ? "↓\(line.git.behind)" : ""
        changesLabel.stringValue = "●\(line.git.changes)"
        toolTip = LocationChip.detailLines(cwd: line.cwd, git: line.git).joined(separator: "\n")
        guard let account = line.account else {
            chipToken = nil
            return
        }
        let token = "\(account.accountID)|\(account.colorID ?? "")|\(account.agentID ?? "")|\(account.isDefault)"
            + "|\(line.limit?.chip ?? "")|\(line.limit?.summary ?? "")"
        guard token != chipToken else { return }
        chipToken = token
        let theme = ZTheme.current
        let tint = ZTheme.projectColor(id: account.colorID) ?? theme.fg3Color
        accountIcon.image = NSImage(systemSymbolName: "person.crop.circle",
                                    accessibilityDescription: "Account")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        accountIcon.contentTintColor = tint
        accountLabel.attributedStringValue = StatusBarView.accountTitle(
            account, limit: line.limit, tint: tint, font: accountLabel.font ?? ZTheme.monoFont(size: 9))
        accountPill.toolTip = StatusBarView.accountToolTip(account, limit: line.limit)
        needsLayout = true   // the label's width follows the limit
        accountPill.layer?.backgroundColor =
            (account.isDefault ? theme.bg2Color : theme.bg3Color).cgColor
        accountPill.layer?.borderColor =
            (account.isDefault ? theme.borderColor : tint).cgColor
    }

    override func layout() {
        super.layout()
        topBorder.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        let all: [NSView] = [accountPill, cwdLabel, branchIcon, branchLabel,
                             aheadLabel, behindLabel, changesLabel]
        guard let line else {
            all.forEach { $0.isHidden = true }
            return
        }

        let labelWidth = line.account == nil ? 0 : accountLabel.intrinsicContentSize.width + 3
        let aheadW = aheadLabel.stringValue.isEmpty ? 0 : aheadLabel.intrinsicContentSize.width
        let behindW = behindLabel.stringValue.isEmpty ? 0 : behindLabel.intrinsicContentSize.width
        let branchNaturalWidth = branchLabel.intrinsicContentSize.width
        let branchLabelWidth = min(branchNaturalWidth, CGFloat(TileStatusLine.branchLabelMaxWidth))
        let widths = TileStatusLine.Widths(
            accountIcon: Double(Self.accountIconWidth),
            accountLabel: Double(labelWidth),
            branch: TileStatusLine.branchWidth(labelWidth: Double(branchNaturalWidth)),
            aheadBehind: Double(aheadW + behindW + (aheadW > 0 && behindW > 0 ? 4 : 0)),
            changes: Double(changesLabel.intrinsicContentSize.width))
        let parts = line.visibleParts(width: Double(bounds.width), widths: widths)

        let pad = CGFloat(TileStatusLine.padding)
        let gap = CGFloat(TileStatusLine.spacing)
        let midY = (bounds.height - 1) / 2   // centred below the 1pt top border
        func place(_ view: NSView, x: CGFloat, width: CGFloat, height: CGFloat) {
            view.frame = NSRect(x: x, y: (midY - height / 2).rounded(),
                                width: width, height: height)
        }

        var x = pad
        accountPill.isHidden = !parts.account
        if parts.account {
            accountLabel.isHidden = !parts.accountLabel
            let w = Self.accountIconWidth + (parts.accountLabel ? labelWidth : 0)
            let pillHeight = Self.accountPillHeight
            place(accountPill, x: x, width: w, height: pillHeight)
            let icon = Self.accountIconSize
            accountIcon.frame = NSRect(x: 3, y: ((pillHeight - icon) / 2).rounded(),
                                       width: icon, height: icon)
            if parts.accountLabel {
                let h = accountLabel.intrinsicContentSize.height
                accountLabel.frame = NSRect(x: Self.accountIconWidth, y: ((pillHeight - h) / 2).rounded(),
                                            width: labelWidth - 3, height: h)
            }
            x += w + gap
        }

        // Trailing parts first, so the cwd knows what it may take.
        var trailing: CGFloat = 0
        if parts.branch { trailing += CGFloat(widths.branch) + gap }
        if parts.aheadBehind { trailing += CGFloat(widths.aheadBehind) + gap }
        if parts.changes { trailing += CGFloat(widths.changes) + gap }
        let textHeight = cwdLabel.intrinsicContentSize.height
        let cwdWidth = max(0, min(cwdLabel.intrinsicContentSize.width,
                                  bounds.width - pad - x - trailing))
        cwdLabel.isHidden = false
        place(cwdLabel, x: x, width: cwdWidth, height: textHeight)
        x += cwdWidth + gap

        branchIcon.isHidden = !parts.branch
        branchLabel.isHidden = !parts.branch
        if parts.branch {
            place(branchIcon, x: x, width: 11, height: 11)
            // Capped: a longer name truncates at its tail here.
            place(branchLabel, x: x + 14, width: branchLabelWidth, height: textHeight)
            x += CGFloat(widths.branch) + gap
        }
        aheadLabel.isHidden = !(parts.aheadBehind && aheadW > 0)
        behindLabel.isHidden = !(parts.aheadBehind && behindW > 0)
        if parts.aheadBehind {
            if aheadW > 0 { place(aheadLabel, x: x, width: aheadW, height: textHeight) }
            if behindW > 0 {
                place(behindLabel, x: x + aheadW + (aheadW > 0 ? 4 : 0),
                      width: behindW, height: textHeight)
            }
            x += CGFloat(widths.aheadBehind) + gap
        }
        changesLabel.isHidden = !parts.changes
        if parts.changes {
            place(changesLabel, x: x, width: CGFloat(widths.changes), height: textHeight)
        }
    }

    // MARK: - Clicks

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit.isDescendant(of: accountPill) ? accountPill : self
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        super.mouseDown(with: event)   // → TileView.mouseDown → focus the tile
    }
}
