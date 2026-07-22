import AppKit
import ZettyCore

/// Popover body for the clone banner's "How do I merge this back?" affordance —
/// the feature-branch flow with this clone's real branch and paths filled in:
/// update from source → PR (primary) → no-origin local merge fallback.
/// Text only; the automated action lives in the context menu.
@MainActor
final class CloneMergeGuideView: NSViewController {

    private let guide: CloneSupport.SyncGuide

    init(guide: CloneSupport.SyncGuide) {
        self.guide = guide
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = ZTheme.current.bg1Color.cgColor

        let stack = NSStackView(views: [
            Self.body("Your clone's work lives on its own branch, “\(guide.branch)”. "
                + "Update it from the source, resolve conflicts here, then open a PR — "
                + "don't push the clone's main."),
            Self.heading("1 · Update from source (fix conflicts here)"),
            Self.steps([guide.updateStep]),
            Self.heading("2 · Push and open a PR"),
            Self.steps(guide.prSteps),
            Self.heading("No origin? Merge locally into the source instead"),
            Self.steps(guide.localFallbackSteps),
            Self.body("Tip: “Update from Source” (right-click the clone) does step 1 "
                + "for you when the clone is clean."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 460),
        ])
        self.view = root
    }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = ZTheme.current.fgColor
        return label
    }

    private static func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = ZTheme.current.fg2Color
        label.preferredMaxLayoutWidth = 432
        return label
    }

    /// Shell commands → mono font (terminal-adjacent) on the elevated surface.
    private static func steps(_ lines: [String]) -> NSView {
        let stack = NSStackView(views: lines.map { line in
            let label = NSTextField(wrappingLabelWithString: line)
            label.font = ZTheme.monoFont(size: 12)
            label.textColor = ZTheme.current.fgColor
            label.preferredMaxLayoutWidth = 412
            return label
        })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.wantsLayer = true
        stack.layer?.backgroundColor = ZTheme.current.bg2Color.cgColor
        stack.layer?.cornerRadius = 5
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        return stack
    }
}
