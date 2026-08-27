import AppKit
import ZettyGhostty

/// Surface-addressed actions exposed by each pane's gutter.
///
/// Bundled into one value so the recursive `SurfaceNodeView` → `RatioSplitView`
/// builder does not gain another positional callback for every new action.
@MainActor
struct PaneActionWiring {
    let onClose: (UUID) -> Void
    let onBreak: (UUID) -> Void
    let onSplit: (UUID, SplitDirection) -> Void
    let onScrollToBottom: (UUID) -> Void
    /// The `Account ▸` entries for a pane; empty hides the submenu entirely.
    let accountMenu: (UUID) -> [(id: String, title: String, color: NSColor?, isCurrent: Bool)]
    /// Move this pane to that account (respawns it in place).
    let onSetAccount: (UUID, String) -> Void
}

// MARK: - SurfaceNodeView

/// Recursively renders a `SurfaceNode` tree as nested `NSSplitView`s.
///
/// - For `.leaf(surface)`: embeds the registry's persistent `TerminalView`
///   for that surface inside a `LeafContainerView` that draws a subtle focus
///   ring when the pane is focused.  The terminal view is never recreated
///   across re-renders; the registry guarantees identity, preserving the live
///   PTY session.
///
/// - For `.split(direction, ratio, first, second)`: creates an `NSSplitView`
///   (`isVertical = direction == .vertical`), adds the two recursively-built
///   child views, and sets the divider position from `ratio` after layout.
///
/// Pass `focusedSurfaceID` so each leaf container can draw its highlight
/// state correctly on the initial render.  Focus change detection is handled
/// at the `TerminalViewController` level via `NSWindow.firstResponder` KVO.
@MainActor
final class SurfaceNodeView: NSView {

    // MARK: - Init

    /// Build the view hierarchy for `node` using `registry`.
    ///
    /// - Parameters:
    ///   - node: The root of the sub-tree to render.
    ///   - registry: Persistent terminal-view registry.
    ///   - focusedSurfaceID: The currently focused surface; the matching leaf
    ///     draws a focus ring.
    ///   - nodePath: Branch steps from the layout root to `node`, so divider
    ///     drags can be written back to the matching split in the model.
    ///   - onRatioChange: Called when the user drags a split's divider, with
    ///     that split's path and its new first/second ratio.
    init(
        node: SurfaceNode,
        registry: SurfaceRegistry,
        focusedSurfaceID: UUID?,
        showsClose: Bool = false,
        paneActions: PaneActionWiring? = nil,
        nodePath: [SplitBranch] = [],
        onRatioChange: (([SplitBranch], Double) -> Void)? = nil,
        fileTree: FileTreeWiring? = nil
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildContent(
            node: node,
            registry: registry,
            focusedSurfaceID: focusedSurfaceID,
            showsClose: showsClose,
            paneActions: paneActions,
            nodePath: nodePath,
            onRatioChange: onRatioChange,
            fileTree: fileTree
        )
    }

    // MARK: - Per-pane addressing

    /// Every leaf container in this subtree.
    ///
    /// Lets the controller reach individual panes for updates that must NOT
    /// trigger a rebuild — re-rooting a file tree, retheming it, tearing down
    /// its watcher — since rebuilding re-parents live terminal views and steals
    /// first responder.
    func leafContainers() -> [LeafContainerView] {
        var found: [LeafContainerView] = []
        func walk(_ view: NSView) {
            if let leaf = view as? LeafContainerView { found.append(leaf) }
            view.subviews.forEach(walk)
        }
        walk(self)
        return found
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // MARK: - In-place focus update

    /// Updates the focus highlight to `focusedSurfaceID` WITHOUT rebuilding the
    /// view hierarchy. Rebuilding re-parents the live terminal views, which
    /// resigns first responder and prevents the clicked pane from taking
    /// keyboard focus — so focus changes must update borders in place.
    func updateFocus(_ focusedSurfaceID: UUID?) {
        for sub in subviews {
            if let leaf = sub as? LeafContainerView {
                leaf.setFocused(leaf.surfaceID == focusedSurfaceID)
            } else if let split = sub as? RatioSplitView {
                split.updateFocus(focusedSurfaceID)
            }
        }
    }

    // MARK: - Private

    private func buildContent(
        node: SurfaceNode,
        registry: SurfaceRegistry,
        focusedSurfaceID: UUID?,
        showsClose: Bool,
        paneActions: PaneActionWiring?,
        nodePath: [SplitBranch],
        onRatioChange: (([SplitBranch], Double) -> Void)?,
        fileTree: FileTreeWiring?
    ) {
        switch node {

        case .leaf(let surface):
            let terminalView = registry.terminalView(for: surface)
            let container = LeafContainerView(
                surfaceID: surface.id,
                terminalView: terminalView,
                isFocused: surface.id == focusedSurfaceID,
                showsClose: showsClose,
                showsFileTree: surface.fileTreeVisible,
                fileTreeWidth: surface.fileTreeWidth
                    ?? fileTree?.settings().width ?? FileTreeSettings.defaultWidth,
                fileTree: fileTree,
                paneActions: paneActions
            )
            container.translatesAutoresizingMaskIntoConstraints = false
            addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: topAnchor),
                container.leadingAnchor.constraint(equalTo: leadingAnchor),
                container.trailingAnchor.constraint(equalTo: trailingAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

        case .split(let direction, let ratio, let first, let second):
            let splitView = RatioSplitView(
                direction: direction,
                ratio: ratio,
                first: first,
                second: second,
                registry: registry,
                focusedSurfaceID: focusedSurfaceID,
                showsClose: showsClose,
                paneActions: paneActions,
                nodePath: nodePath,
                onRatioChange: onRatioChange,
                fileTree: fileTree
            )
            splitView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(splitView)
            NSLayoutConstraint.activate([
                splitView.topAnchor.constraint(equalTo: topAnchor),
                splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
                splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
                splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
}

// MARK: - LeafContainerView

/// A thin wrapper view that embeds a `TerminalView` and floats the pane's
/// chrome — a focus status dot and action buttons — in a top gutter.
///
/// The gutter is always present so the split buttons are reachable even from a
/// lone pane. `showsClose` (true only when the tab holds more than one pane)
/// additionally reveals the break-into-tab and × buttons, which are no-ops on a
/// single pane.
@MainActor
final class LeafContainerView: NSView {

    private static let borderWidth: CGFloat = 2
    /// Top strip reserved for the chrome buttons, so they never overlap the
    /// terminal's first line.
    private static let gutterHeight: CGFloat = 24
    /// Square edge of each gutter button.
    private static let buttonSize: CGFloat = 18
    private static let minFileTreeWidth: CGFloat = 140
    private static let maxFileTreeWidth: CGFloat = 520

    let surfaceID: UUID
    private var isFocused: Bool
    private var paneActions: PaneActionWiring?
    private var statusDot: NSView?

    private var fileTreeWiring: FileTreeWiring?
    private var fileTree: FileTreeView?
    private var terminalLeadingToContainer: NSLayoutConstraint?
    private var fileTreeWidthConstraint: NSLayoutConstraint?

    init(
        surfaceID: UUID,
        terminalView: NSView,
        isFocused: Bool,
        showsClose: Bool,
        showsFileTree: Bool = false,
        fileTreeWidth: Double = FileTreeSettings.defaultWidth,
        fileTree: FileTreeWiring? = nil,
        paneActions: PaneActionWiring? = nil
    ) {
        self.surfaceID = surfaceID
        self.isFocused = isFocused
        self.paneActions = paneActions
        self.fileTreeWiring = fileTree
        super.init(frame: .zero)
        wantsLayer = true
        // Rounded, themed pane surface (handoff: 10pt radius panes on bg1).
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = ZTheme.current.bg1Color.cgColor

        let inset = LeafContainerView.borderWidth
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        // Two leading constraints, one active at a time: pinned to the pane
        // edge normally, or to the file tree's divider when a tree is shown.
        // Swapping beats rebuilding the constraint set on every toggle.
        let leadingToContainer = terminalView.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: inset)
        terminalLeadingToContainer = leadingToContainer
        NSLayoutConstraint.activate([
            // The gutter inset keeps the chrome buttons above the terminal
            // content instead of overlapping its first line.
            terminalView.topAnchor.constraint(equalTo: topAnchor,
                                              constant: LeafContainerView.gutterHeight),
            leadingToContainer,
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])

        addStatusDot()
        addGutterButtons(showsClose: showsClose, showsFileTree: showsFileTree)
        menu = makePaneMenu(showsClose: showsClose, showsFileTree: showsFileTree)

        if showsFileTree, let wiring = fileTree {
            installFileTree(width: fileTreeWidth, wiring: wiring, terminalView: terminalView)
        }

        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // MARK: - File tree

    /// Slots the file tree onto the pane's leading edge and re-pins the terminal
    /// beside it, with a 1pt divider carrying the drag handle.
    private func installFileTree(width: Double, wiring: FileTreeWiring, terminalView: NSView) {
        let tree = FileTreeView(settingsProvider: wiring.settings)
        tree.onActivateFile = wiring.onPeek
        tree.onOpenInEditor = wiring.onOpenInEditor
        tree.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tree)
        fileTree = tree

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = ZTheme.current.borderColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        let inset = LeafContainerView.borderWidth
        let clamped = min(max(CGFloat(width), Self.minFileTreeWidth), Self.maxFileTreeWidth)
        let widthConstraint = tree.widthAnchor.constraint(equalToConstant: clamped)
        fileTreeWidthConstraint = widthConstraint

        terminalLeadingToContainer?.isActive = false
        NSLayoutConstraint.activate([
            tree.topAnchor.constraint(equalTo: topAnchor,
                                      constant: LeafContainerView.gutterHeight),
            tree.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            tree.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            widthConstraint,

            divider.leadingAnchor.constraint(equalTo: tree.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: tree.topAnchor),
            divider.bottomAnchor.constraint(equalTo: tree.bottomAnchor),

            terminalView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
        ])

        let handle = FileTreeDragHandle { [weak self] delta in
            guard let self, let widthConstraint = self.fileTreeWidthConstraint else { return }
            let next = min(max(widthConstraint.constant + delta, Self.minFileTreeWidth),
                           Self.maxFileTreeWidth)
            widthConstraint.constant = next
            self.fileTreeWiring?.onWidthChange(self.surfaceID, Double(next))
        }
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)
        NSLayoutConstraint.activate([
            handle.centerXAnchor.constraint(equalTo: divider.centerXAnchor),
            handle.widthAnchor.constraint(equalToConstant: 8),
            handle.topAnchor.constraint(equalTo: divider.topAnchor),
            handle.bottomAnchor.constraint(equalTo: divider.bottomAnchor),
        ])
    }

    /// Points this pane's tree at `path`. No-op when the tree is hidden.
    func setFileTreeRoot(_ path: String, expanding: Set<String>) {
        fileTree?.setRoot(path, expanding: expanding)
    }

    var fileTreeCurrentRoot: String? { fileTree?.root }
    var fileTreeExpandedDirectories: Set<String> { fileTree?.expandedDirectories ?? [] }
    var hasFileTree: Bool { fileTree != nil }
    func stopFileTreeWatching() { fileTree?.stopWatching() }
    // No `applyTheme` forwarder: a scheme change runs through
    // `rebuildSurfaceNodeView()`, which recreates every tree, so the theme is
    // picked up in `FileTreeView.init`. Nothing to invalidate.

    /// Updates the focus state + border in place (no rebuild).
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        updateBorder()
    }

    private func updateBorder() {
        // No pane border by design; focus is conveyed by the accent status dot.
        layer?.borderWidth = 0
        let theme = ZTheme.current
        statusDot?.layer?.backgroundColor = isFocused
            ? theme.accentColor.cgColor
            : theme.fg3Color.cgColor
    }

    /// A small status dot floated top-left in the gutter, echoing the handoff's
    /// pane header (accent when focused, dim otherwise).
    private func addStatusDot() {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
        ])
        statusDot = dot
    }

    /// Lays the gutter actions out right-to-left from the trailing edge:
    /// split-vertical · split-horizontal · break · close.
    /// The split pair is always available; break and × only when the pane is
    /// closable. Scroll-to-bottom is deliberately NOT here — its button did
    /// nothing in panes running an agent CLI and the cause is unfound, so the
    /// action stays on the pane's right-click menu and ⌘↓ until it's diagnosed.
    private func addGutterButtons(showsClose: Bool, showsFileTree: Bool) {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])

        if fileTreeWiring != nil {
            stack.addArrangedSubview(makeGutterButton(
                symbol: "sidebar.left", fallback: "▤",
                toolTip: showsFileTree ? "Hide file tree" : "Show file tree",
                action: #selector(toggleFileTreeTapped)
            ))
        }

        // "2x1" = two columns (a vertical divider), "1x2" = two rows.
        stack.addArrangedSubview(makeGutterButton(
            symbol: "square.split.2x1", fallback: "⇹",
            toolTip: "Split vertically", action: #selector(splitVerticalTapped)
        ))
        stack.addArrangedSubview(makeGutterButton(
            symbol: "square.split.1x2", fallback: "⇳",
            toolTip: "Split horizontally", action: #selector(splitHorizontalTapped)
        ))

        guard showsClose else { return }
        stack.addArrangedSubview(makeGutterButton(
            symbol: "arrow.up.forward.square", fallback: "↗",
            toolTip: "Break pane into tab", action: #selector(breakButtonTapped)
        ))
        stack.addArrangedSubview(makeGutterButton(
            symbol: "xmark", fallback: "×",
            toolTip: "Close pane", action: #selector(closeButtonTapped)
        ))
    }

    private func makeGutterButton(
        symbol: String,
        fallback: String,
        toolTip: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .circular
        button.isBordered = false
        button.title = ""
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) {
            button.image = image
        } else {
            button.title = fallback
        }
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = ZTheme.current.fg3Color
        button.toolTip = toolTip
        button.target = self
        button.action = action
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: LeafContainerView.buttonSize),
            button.heightAnchor.constraint(equalToConstant: LeafContainerView.buttonSize),
        ])
        return button
    }

    @objc private func closeButtonTapped() {
        paneActions?.onClose(surfaceID)
    }

    @objc private func breakButtonTapped() {
        paneActions?.onBreak(surfaceID)
    }

    @objc private func splitVerticalTapped() {
        paneActions?.onSplit(surfaceID, .vertical)
    }

    @objc private func splitHorizontalTapped() {
        paneActions?.onSplit(surfaceID, .horizontal)
    }

    @objc private func scrollToBottomTapped() {
        paneActions?.onScrollToBottom(surfaceID)
    }

    @objc private func toggleFileTreeTapped() {
        fileTreeWiring?.onToggle(surfaceID)
    }

    /// Right-click menu for the pane chrome (gutter). The terminal view fills
    /// the container below the gutter and handles its own right-click, so this
    /// menu appears only on the pane chrome — not over the terminal content.
    private func makePaneMenu(showsClose: Bool, showsFileTree: Bool) -> NSMenu {
        let menu = NSMenu()
        if fileTreeWiring != nil {
            menu.addItem(makeMenuItem(showsFileTree ? "Hide File Tree" : "Show File Tree",
                                      #selector(toggleFileTreeTapped)))
            menu.addItem(.separator())
        }
        menu.addItem(makeMenuItem("Scroll to Bottom", #selector(scrollToBottomTapped)))
        menu.addItem(.separator())
        // Only when accounts exist — otherwise there is nothing to move between.
        let accounts = paneActions?.accountMenu(surfaceID) ?? []
        if accounts.count > 1 {
            let submenu = NSMenu()
            for entry in accounts {
                let item = NSMenuItem(title: entry.title,
                                      action: #selector(accountPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                item.state = entry.isCurrent ? .on : .off
                if let color = entry.color { item.image = Self.dotImage(color) }
                submenu.addItem(item)
            }
            let parent = NSMenuItem(title: "Account", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
            menu.addItem(.separator())
        }
        menu.addItem(makeMenuItem("Split Vertically", #selector(splitVerticalTapped)))
        menu.addItem(makeMenuItem("Split Horizontally", #selector(splitHorizontalTapped)))
        guard showsClose else { return menu }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Break Pane into Tab", #selector(breakButtonTapped)))
        menu.addItem(makeMenuItem("Close Pane", #selector(closeButtonTapped)))
        return menu
    }

    /// Picking the account the pane already runs on must not tear down a
    /// working pane, so the no-op is checked before anything else.
    @objc private func accountPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, sender.state != .on else { return }
        paneActions?.onSetAccount(surfaceID, id)
    }

    /// A small filled circle for an account's identity color.
    private static func dotImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    private func makeMenuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}

// MARK: - RatioSplitView

/// An `NSSplitView` that respects a `ratio` (0…1) for its single divider.
///
/// Because `setPosition(_:ofDividerAt:)` is only meaningful after the split
/// view has a non-zero frame, the ratio is applied in `layout()` on the first
/// pass where the bounds are non-empty.  Subsequent layout calls leave the
/// divider alone so user drags are preserved.
///
/// Divider drags are written back to the model: once the initial position is
/// set, any meaningful ratio change (a drag; window resizes keep proportions)
/// is reported through `onRatioChange` with this split's `nodePath`, so the
/// persisted layout matches what's on screen.
@MainActor
private final class RatioSplitView: NSSplitView, NSSplitViewDelegate {

    private let ratio: Double
    private var didSetInitialPosition = false
    private let nodePath: [SplitBranch]
    private let onRatioChange: (([SplitBranch], Double) -> Void)?
    private var lastReportedRatio: Double

    init(
        direction: SplitDirection,
        ratio: Double,
        first: SurfaceNode,
        second: SurfaceNode,
        registry: SurfaceRegistry,
        focusedSurfaceID: UUID?,
        showsClose: Bool = false,
        paneActions: PaneActionWiring? = nil,
        nodePath: [SplitBranch] = [],
        onRatioChange: (([SplitBranch], Double) -> Void)? = nil,
        fileTree: FileTreeWiring? = nil
    ) {
        self.ratio = ratio
        self.nodePath = nodePath
        self.onRatioChange = onRatioChange
        self.lastReportedRatio = ratio
        super.init(frame: .zero)
        isVertical = (direction == .vertical)
        dividerStyle = .thin
        delegate = self

        let firstView = SurfaceNodeView(
            node: first,
            registry: registry,
            focusedSurfaceID: focusedSurfaceID,
            showsClose: showsClose,
            paneActions: paneActions,
            nodePath: nodePath + [.first],
            onRatioChange: onRatioChange,
            fileTree: fileTree
        )
        let secondView = SurfaceNodeView(
            node: second,
            registry: registry,
            focusedSurfaceID: focusedSurfaceID,
            showsClose: showsClose,
            paneActions: paneActions,
            nodePath: nodePath + [.second],
            onRatioChange: onRatioChange,
            fileTree: fileTree
        )
        addArrangedSubview(firstView)
        addArrangedSubview(secondView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// Forwards an in-place focus update to both child sub-trees.
    func updateFocus(_ focusedSurfaceID: UUID?) {
        for sub in arrangedSubviews {
            (sub as? SurfaceNodeView)?.updateFocus(focusedSurfaceID)
        }
    }

    override func layout() {
        super.layout()
        applyInitialRatioIfNeeded()
    }

    private func applyInitialRatioIfNeeded() {
        guard !didSetInitialPosition else { return }
        let dimension = isVertical ? bounds.width : bounds.height
        guard dimension > 0 else { return }
        didSetInitialPosition = true
        let position = dimension * ratio
        setPosition(position, ofDividerAt: 0)
    }

    // MARK: - NSSplitViewDelegate

    func splitViewDidResizeSubviews(_: Notification) {
        // Ignore resizes until the persisted ratio has been applied, so the
        // pre-layout default position never overwrites the model.
        guard didSetInitialPosition, arrangedSubviews.count == 2 else { return }
        let dimension = isVertical ? bounds.width : bounds.height
        guard dimension > 0 else { return }
        let firstFrame = arrangedSubviews[0].frame
        let current = Double((isVertical ? firstFrame.width : firstFrame.height) / dimension)
        // Proportional window resizes wobble by sub-pixel amounts; only a real
        // divider drag moves the ratio enough to be worth writing back.
        guard abs(current - lastReportedRatio) > 0.001 else { return }
        lastReportedRatio = current
        onRatioChange?(nodePath, current)
    }
}

// MARK: - FileTreeDragHandle

/// Invisible 8pt strip over the file tree / terminal divider that reports
/// horizontal drag deltas. Cursor rect only — it draws nothing.
@MainActor
private final class FileTreeDragHandle: NSView {
    private let onDrag: (CGFloat) -> Void
    private var lastX: CGFloat = 0

    init(onDrag: @escaping (CGFloat) -> Void) {
        self.onDrag = onDrag
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        // The handle moves with the divider as the width constraint updates, so
        // each delta is measured from the handle's own new origin — accumulating
        // absolute x would double-count the movement.
        let x = convert(event.locationInWindow, from: nil).x
        onDrag(x - lastX)
    }
}
