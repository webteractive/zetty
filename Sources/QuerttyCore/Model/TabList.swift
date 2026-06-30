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

    /// Creates a list seeded with one fresh single-pane tab.
    public init() {
        trees = [TabList.freshTree()]
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
    public convenience init?(restoring trees: [PaneTree], activeIndex: Int = 0) {
        guard !trees.isEmpty else { return nil }
        self.init()
        self.trees = trees
        self.activeIndex = min(max(activeIndex, 0), trees.count - 1)
    }

    /// The `PaneTree` for the current tab.
    public var activeTree: PaneTree {
        get { trees[activeIndex] }
        set { trees[activeIndex] = newValue }
    }

    /// Appends a new single-pane tab and makes it active.
    public func newTab() {
        trees.append(TabList.freshTree())
        activeIndex = trees.count - 1
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

    private static func freshTree() -> PaneTree {
        let surface = Surface(workingDir: NSHomeDirectory())
        return PaneTree(layout: Layout(root: .leaf(surface)), focusedSurfaceID: surface.id)
    }
}
