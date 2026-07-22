import AppKit
import ZettyCore

/// A full-width caution strip shown below the tab bar whenever the active
/// project is a clone (copy-on-write fork). It reminds the user that a clone's
/// working copy is disposable: uncommitted changes vanish when the clone is
/// removed, so durable work must be committed + pushed to origin or landed
/// back into the source branch.
///
/// For git clones (branch/clonePath/sourcePath all present) it also shows a
/// trailing "How do I merge this back?" button that opens an `NSPopover` with
/// the feature-branch sync guide (`CloneMergeGuideView`).
///
/// Recreated on every `rebuildSurfaceNodeView()` (so it appears/disappears as
/// the active project switches), it reads `ZTheme.current` at init like the
/// other content-area chrome (`HibernationPlaceholderView`). Uses the semantic
/// `yellow` = attention token — depth is surface + border, never shadow.
@MainActor
final class CloneWarningBanner: NSView {

    static let height: CGFloat = 26

    private let fallbackBranch: String?
    private let clonePath: String?
    private let sourcePath: String?
    private var popover: NSPopover?

    /// `fallbackBranch` is a cheap, display-derived guess (from the renamable
    /// project name) used only if a live git read fails at click time — see
    /// `showGuide`. `clonePath`/`sourcePath` nil → the clone is not a git repo;
    /// the merge affordance is hidden.
    init(fallbackBranch: String? = nil, clonePath: String? = nil, sourcePath: String? = nil) {
        self.fallbackBranch = fallbackBranch
        self.clonePath = clonePath
        self.sourcePath = sourcePath
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = ZTheme.current.bg2Color.cgColor

        // 2pt yellow accent bar down the leading edge.
        let accentBar = NSView()
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = ZTheme.current.yellowColor.cgColor
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)

        // 1pt hairline separating the banner from the terminal below.
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = ZTheme.current.borderColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: "Clone warning")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        icon.contentTintColor = ZTheme.current.yellowColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithAttributedString: Self.message())
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        let arranged: [NSView]
        if clonePath != nil, sourcePath != nil {
            let button = NSButton(title: "", target: self, action: #selector(showGuide(_:)))
            button.isBordered = false
            button.attributedTitle = NSAttributedString(
                string: "How do I merge this back?",
                attributes: [.font: ZTheme.monoFont(size: 12),
                             .foregroundColor: ZTheme.current.accentColor])
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.translatesAutoresizingMaskIntoConstraints = false
            arranged = [icon, label, button]
        } else {
            arranged = [icon, label]
        }

        let stack = NSStackView(views: arranged)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 2),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    @objc private func showGuide(_ sender: NSButton) {
        guard let clonePath, let sourcePath else { return }
        // Repo-truthful branch, resolved lazily on click (not in the hot
        // rebuild path) — robust against the project having been renamed.
        let branch = CloneRunner.currentBranch(in: clonePath) ?? fallbackBranch ?? "HEAD"
        let guide = CloneSupport.syncGuide(
            branch: branch, clonePath: clonePath, sourcePath: sourcePath, defaultBranch: "main")
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = CloneMergeGuideView(guide: guide)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        self.popover = popover
    }

    /// Bold lead-in ("Clone (copy-on-write).") + regular guidance, so the
    /// warning reads as one prose sentence in the content area's system font.
    private static func message() -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: "Clone (copy-on-write). ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: ZTheme.current.fgColor,
            ])
        result.append(NSAttributedString(
            string: "Commit and push to origin, or merge back into the source branch — uncommitted changes are lost when this clone is removed.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: ZTheme.current.fg2Color,
            ]))
        return result
    }
}
