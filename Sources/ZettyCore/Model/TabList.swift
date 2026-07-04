import Foundation

/// A list of tabs — one `PaneTree` each — plus the active-tab index.
///
/// Pure model logic (no UI). The app's `TabBarView` renders it and
/// `TerminalViewController` forwards its active `PaneTree` to `PaneActions`,
/// so split/close/focus operate on the active tab without knowing about tabs.
///
/// Invariant: `trees` is always non-empty and `activeIndex` always points at a
/// valid tab.
public final class TabList {

    /// One `PaneTree` per tab, always non-empty.
    public private(set) var trees: [PaneTree]

    /// Index into `trees` for the active tab.
    public private(set) var activeIndex: Int

    /// Working directory new tabs/panes spawn in (e.g. the owning project's root).
    private let defaultWorkingDir: String

    /// Creates a list seeded with one fresh single-pane tab whose terminal opens
    /// in `defaultWorkingDir` (defaults to the user's home directory).
    public init(defaultWorkingDir: String = NSHomeDirectory()) {
        self.defaultWorkingDir = defaultWorkingDir
        trees = [TabList.freshTree(workingDir: defaultWorkingDir)]
        activeIndex = 0
    }

    /// Creates a list restored from saved `PaneTree`s.
    ///
    /// Returns `nil` when `trees` is empty so callers can fall back to
    /// `init()` (a fresh single-pane tab) without special-casing nil.
    ///
    /// - Parameters:
    ///   - trees: Non-empty array of restored `PaneTree`s.
    ///   - activeIndex: Index of the tab to select initially; clamped to a
    ///     valid range automatically.
    ///   - defaultWorkingDir: Directory new tabs/panes spawn in (the owning
    ///     project's root) — carried across restore so it isn't lost to `~`.
    public convenience init?(restoring trees: [PaneTree], activeIndex: Int = 0,
                             defaultWorkingDir: String = NSHomeDirectory()) {
        guard !trees.isEmpty else { return nil }
        self.init(defaultWorkingDir: defaultWorkingDir)
        self.trees = trees
        self.activeIndex = min(max(activeIndex, 0), trees.count - 1)
    }

    /// The `PaneTree` for the current tab.
    public var activeTree: PaneTree {
        get { trees[activeIndex] }
        set { trees[activeIndex] = newValue }
    }

    /// Replaces the whole tab set with another list's (layout-template
    /// application). `other` is never empty by TabList's own invariant, so
    /// this list's invariant holds too.
    public func replaceTrees(from other: TabList) {
        trees = other.trees
        activeIndex = other.activeIndex
    }

    /// Appends a new single-pane tab and makes it active.
    public func newTab() {
        trees.append(TabList.freshTree(workingDir: defaultWorkingDir))
        activeIndex = trees.count - 1
    }

    /// Move the active tab's focused pane into a new single-pane tab inserted
    /// right after the current tab, which becomes active. The moved `Surface`
    /// keeps its identity (id/workingDir/command/lastTitle), so the live
    /// terminal is re-parented rather than recreated. Returns false (no-op)
    /// when the active tab has a single pane or no focused surface.
    @discardableResult
    public func breakFocusedPaneIntoNewTab() -> Bool {
        var tree = activeTree
        guard tree.layout.surfaces.count > 1,
              let id = tree.focusedSurfaceID,
              let surface = tree.layout.surfaces.first(where: { $0.id == id }) else {
            return false
        }
        // Removing via closeFocused reuses the collapse + source-focus fix and
        // clears the source tab's zoom if the moved pane was the zoomed one.
        guard tree.closeFocused() else { return false }
        activeTree = tree

        let newTree = PaneTree(layout: Layout(root: .leaf(surface)),
                               focusedSurfaceID: surface.id)
        trees.insert(newTree, at: activeIndex + 1)
        activeIndex += 1
        return true
    }

    /// Closes the tab at `index`. No-op if it would remove the last tab or the
    /// index is out of range. After closing, `activeIndex` stays on a valid tab
    /// (and on the same logical tab when one before it is removed).
    public func closeTab(at index: Int) {
        guard trees.count > 1, trees.indices.contains(index) else { return }
        trees.remove(at: index)
        if activeIndex >= trees.count {
            activeIndex = trees.count - 1
        } else if index < activeIndex {
            activeIndex -= 1
        }
    }

    /// Moves the tab at `source` to `destination` (drag-to-reorder).
    /// `activeIndex` keeps pointing at the same logical tab. No-op when
    /// either index is out of range or they're equal.
    public func moveTab(from source: Int, to destination: Int) {
        guard source != destination,
              trees.indices.contains(source),
              trees.indices.contains(destination) else { return }
        let tree = trees.remove(at: source)
        trees.insert(tree, at: destination)
        if activeIndex == source {
            activeIndex = destination
        } else if source < activeIndex, destination >= activeIndex {
            activeIndex -= 1
        } else if source > activeIndex, destination <= activeIndex {
            activeIndex += 1
        }
    }

    /// Selects the tab at `index`. No-op if out of range.
    public func select(index: Int) {
        guard trees.indices.contains(index) else { return }
        activeIndex = index
    }

    /// Selects the next tab, wrapping around.
    public func selectNext() {
        activeIndex = (activeIndex + 1) % trees.count
    }

    /// Selects the previous tab, wrapping around.
    public func selectPrevious() {
        activeIndex = (activeIndex - 1 + trees.count) % trees.count
    }

    /// Sets the manual title on the tab at `index`.
    ///
    /// Pass `nil` to clear the override and revert to the auto-computed name.
    /// No-op if `index` is out of range.
    public func setManualTitle(_ title: String?, at index: Int) {
        guard trees.indices.contains(index) else { return }
        trees[index].manualTitle = title
    }

    /// Human-readable, positional title for the tab at `index`.
    public func title(at index: Int) -> String {
        "Tab \(index + 1)"
    }

    /// Mutate the leaf surface with `id` in whichever tree holds it (e.g. its
    /// persisted title). Returns false if no tab contains that surface.
    @discardableResult
    public func updateSurface(_ id: UUID, _ mutate: (inout Surface) -> Void) -> Bool {
        for index in trees.indices {
            if trees[index].layout.update(surfaceID: id, mutate) { return true }
        }
        return false
    }

    private static func freshTree(workingDir: String) -> PaneTree {
        let surface = Surface(workingDir: workingDir)
        return PaneTree(layout: Layout(root: .leaf(surface)), focusedSurfaceID: surface.id)
    }
}
