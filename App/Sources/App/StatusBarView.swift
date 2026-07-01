import AppKit
import QuerttyCore

// MARK: - StatusBarView

/// The bottom status strip (handoff: 28pt, `bg0`, mono 11). Three zones:
/// a left **git** cluster (branch · ↑ahead ↓behind · ●changes), the focused
/// pane's working directory centered, and a right cluster of ambient info
/// (active color scheme · shell · libghostty version).
///
/// The view is dumb: `update(...)` and `updateGit(...)` set content;
/// `applyTheme()` re-reads colors/fonts from `QTheme` on a scheme change.
@MainActor
final class StatusBarView: NSView {

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

    // Right: scheme · shell · libghostty.
    private let schemeDot = NSView()
    private let schemeLabel = NSTextField(labelWithString: "")
    private let sep1 = NSTextField(labelWithString: "·")
    private let shellLabel = NSTextField(labelWithString: "")
    private let sep2 = NSTextField(labelWithString: "·")
    private let ghosttyLabel = NSTextField(labelWithString: "")
    private let rightStack = NSStackView()

    private var allLabels: [NSTextField] {
        [branchLabel, aheadLabel, behindLabel, changesLabel,
         cwdLabel, schemeLabel, sep1, shellLabel, sep2, ghosttyLabel]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        for label in allLabels {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        // The path is likeliest to overflow — keep its tail visible, let it shrink.
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

        configureStack(leftStack, views: [branchIcon, branchLabel, aheadLabel, behindLabel, changesLabel])
        configureStack(rightStack, views: [schemeDot, schemeLabel, sep1, shellLabel, sep2, ghosttyLabel])

        addSubview(topBorder)
        addSubview(leftStack)
        addSubview(cwdLabel)
        addSubview(rightStack)

        let cwdCenter = cwdLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        cwdCenter.priority = .defaultLow   // yields to the leading/trailing limits when tight

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

    // MARK: - Content

    func update(cwd: String, scheme: String, shell: String, ghostty: String) {
        cwdLabel.stringValue = cwd
        schemeLabel.stringValue = scheme
        shellLabel.stringValue = shell
        ghosttyLabel.stringValue = ghostty
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
        for label in allLabels { label.font = font }

        cwdLabel.textColor = theme.fg2Color
        branchLabel.textColor = theme.purpleColor
        aheadLabel.textColor = theme.greenColor
        behindLabel.textColor = theme.redColor
        changesLabel.textColor = theme.yellowColor
        schemeLabel.textColor = theme.accentColor
        shellLabel.textColor = theme.fg2Color
        ghosttyLabel.textColor = theme.fg2Color
        sep1.textColor = theme.fg3Color
        sep2.textColor = theme.fg3Color
    }
}
