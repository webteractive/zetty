import AppKit
import QuerttyCore
import QuerttyGhostty

// MARK: - TerminalViewController

/// Hosts a recursive split-pane terminal layout driven by a `PaneTree`.
///
/// # Layout model
/// `paneTree.layout.root` is a `SurfaceNode` tree.  Each time the tree
/// changes, `rebuildSurfaceNodeView()` replaces the root content view with a
/// fresh `SurfaceNodeView`.  Unchanged leaf panes share their persistent
/// `TerminalView` from `registry`, so splits never kill a sibling session.
///
/// # Session ownership
/// The live PTY lives inside `TerminalView` (AppTerminalView) via its
/// embedded `TerminalSurfaceCoordinator → TerminalSurface`.
/// `TerminalController` only owns the ghostty app/config lifecycle.
/// `SurfaceRegistry` retains both; `prune(keeping:)` tears down removed panes.
///
/// # Default window
/// Seeds the tree with a single leaf — one terminal, matching Phase 0 behaviour.
///
/// # Debug split
/// To visually verify two-pane rendering without running the app, set
/// `debugTwoPane = true` below.  Revert before shipping.
final class TerminalViewController: NSViewController {

    // MARK: - Debug flag (REVERT before committing)
    //
    // Set to `true` temporarily to seed a two-leaf vertical split so the
    // build proves the split path compiles.  The default (false) gives the
    // normal single-pane window.
    private static let debugTwoPane: Bool = false

    // MARK: - State

    /// Shared registry — persists terminal views across re-renders.
    private let registry = SurfaceRegistry()

    /// The logical pane tree.  Mutate this, then call `rebuildSurfaceNodeView()`.
    /// Declared `internal` so the `PaneActions` extension (same module) can write it.
    var paneTree: PaneTree = {
        let surface = Surface(workingDir: NSHomeDirectory())
        let layout = Layout(root: .leaf(surface))
        var tree = PaneTree(layout: layout, focusedSurfaceID: surface.id)

        // DEBUG: temporary two-pane seed — revert to single-leaf before shipping.
        if TerminalViewController.debugTwoPane {
            let second = Surface(workingDir: NSHomeDirectory())
            tree.splitFocused(direction: .vertical, newSurface: second)
        }

        return tree
    }()

    /// The currently installed root content view (a `SurfaceNodeView`).
    private var rootContentView: SurfaceNodeView?

    /// KVO token for observing `window.firstResponder`.
    private var firstResponderObservation: NSKeyValueObservation?

    // MARK: - View lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuildSurfaceNodeView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Give focus to whichever terminal the PaneTree considers focused.
        if let focused = focusedTerminalView() {
            view.window?.makeFirstResponder(focused)
        }
        // Observe first-responder changes on the window to track which pane the
        // user clicks into.  `AppTerminalView.onFocusChange` is `internal` to
        // GhosttyTerminal, so KVO on `NSWindow.firstResponder` is the only
        // cross-module way to detect the transition.
        startObservingFirstResponder()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        firstResponderObservation = nil
    }

    // MARK: - First-responder observation

    /// Starts (or restarts) KVO on `window.firstResponder`.
    ///
    /// When the first responder changes we walk its superview chain looking for
    /// a terminal view we recognise from the registry.  Finding one means the
    /// user clicked into that pane, so we update `paneTree.focusedSurfaceID`
    /// and redraw the focus highlights.
    private func startObservingFirstResponder() {
        guard let window = view.window else { return }
        firstResponderObservation = window.observe(
            \.firstResponder,
            options: [.new]
        ) { [weak self] _, _ in
            // observe is called on whatever thread AppKit uses; bounce to main.
            DispatchQueue.main.async {
                self?.handleFirstResponderChange()
            }
        }
    }

    private func handleFirstResponderChange() {
        guard let responder = view.window?.firstResponder as? NSView else { return }
        // Walk the superview chain of the new first responder to find which
        // registry view it belongs to (the terminal view itself, or a child of it).
        if let surfaceID = registry.surfaceID(containing: responder) {
            focusChanged(surfaceID: surfaceID)
        }
    }

    // MARK: - Tree rendering

    /// Replaces the root content view with a freshly-built `SurfaceNodeView`
    /// derived from `paneTree.layout.root`.
    ///
    /// After building, prunes the registry to release controllers/views for
    /// any surfaces that are no longer in the tree.
    ///
    /// Declared `internal` so the `PaneActions` extension (same module) can call it.
    func rebuildSurfaceNodeView() {
        rootContentView?.removeFromSuperview()

        let newRoot = SurfaceNodeView(
            node: paneTree.layout.root,
            registry: registry,
            focusedSurfaceID: paneTree.focusedSurfaceID
        )
        newRoot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newRoot)
        NSLayoutConstraint.activate([
            newRoot.topAnchor.constraint(equalTo: view.topAnchor),
            newRoot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newRoot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            newRoot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        rootContentView = newRoot

        let liveIDs = Set(paneTree.layout.surfaces.map(\.id))
        registry.prune(keeping: liveIDs)
    }

    // MARK: - Helpers

    /// Returns the `NSView` for the currently focused surface, if any.
    /// Declared `internal` so the `PaneActions` extension (same module) can call it.
    func focusedTerminalView() -> NSView? {
        guard let surface = paneTree.focusedSurface else { return nil }
        return registry.terminalView(for: surface)
    }

    // MARK: - Focus tracking

    /// Called whenever the KVO observer detects a first-responder change to a
    /// known terminal view.
    ///
    /// Updates `paneTree.focusedSurfaceID` and re-renders so the focus
    /// highlight moves to the newly focused leaf.  Rebuilding replaces
    /// `SurfaceNodeView` (cheap — it is a lightweight wrapper; terminal views
    /// are stable inside the registry), restarts the first-responder observer
    /// on the same window, and re-issues `makeFirstResponder` — which is a
    /// no-op when the terminal already has focus.
    private func focusChanged(surfaceID: UUID) {
        guard paneTree.focusedSurfaceID != surfaceID else { return }
        paneTree.focus(surfaceID)
        rebuildSurfaceNodeView()
        // No need to re-observe: the KVO target is the (unchanged) window, and
        // rebuildSurfaceNodeView only swaps the view hierarchy.
    }
}
