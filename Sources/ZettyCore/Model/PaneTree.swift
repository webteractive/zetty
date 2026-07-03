import Foundation

public struct PaneTree: Codable, Sendable, Equatable {
    public var layout: Layout
    public var focusedSurfaceID: UUID?
    public var manualTitle: String?
    /// Zoomed (temporarily maximized) pane, if any. Transient by design —
    /// excluded from `CodingKeys` so it never persists to `workspace.json`,
    /// matching tmux's zoom semantics.
    public var zoomedSurfaceID: UUID?

    private enum CodingKeys: String, CodingKey {
        case layout, focusedSurfaceID, manualTitle
    }

    public init(layout: Layout, focusedSurfaceID: UUID? = nil, manualTitle: String? = nil) {
        self.layout = layout
        self.focusedSurfaceID = focusedSurfaceID
        self.manualTitle = manualTitle
    }

    public var focusedSurface: Surface? {
        guard let id = focusedSurfaceID else { return nil }
        return layout.surfaces.first { $0.id == id }
    }

    /// Split the focused leaf; focus moves to `newSurface`. False if no focus / not found.
    /// Splitting always unzooms — the new pane must be visible.
    @discardableResult
    public mutating func splitFocused(direction: SplitDirection, newSurface: Surface, ratio: Double = 0.5) -> Bool {
        guard let id = focusedSurfaceID else { return false }
        guard layout.split(surfaceID: id, direction: direction, newSurface: newSurface, ratio: ratio) else { return false }
        focusedSurfaceID = newSurface.id
        zoomedSurfaceID = nil
        return true
    }

    /// Close the focused leaf; focus moves to the first remaining surface. False if it was the only one.
    @discardableResult
    public mutating func closeFocused() -> Bool {
        guard let id = focusedSurfaceID else { return false }
        guard layout.close(surfaceID: id) else { return false }
        focusedSurfaceID = layout.surfaces.first?.id
        if zoomedSurfaceID == id { zoomedSurfaceID = nil }
        return true
    }

    /// Focus the surface with `id`; no-op if it isn't in the tree.
    public mutating func focus(_ id: UUID) {
        guard layout.surfaces.contains(where: { $0.id == id }) else { return }
        focusedSurfaceID = id
    }

    /// Move focus to the pane adjacent to the focused one in `direction`.
    /// False when there is no focus or no pane that way (no wrapping).
    @discardableResult
    public mutating func focusNeighbor(_ direction: FocusDirection) -> Bool {
        guard let id = focusedSurfaceID,
              let neighbor = layout.neighbor(of: id, direction: direction) else { return false }
        focusedSurfaceID = neighbor
        return true
    }

    /// Move focus to the next pane in `layout.surfaces` order (first-to-second
    /// tree order), wrapping at the end. False with fewer than two panes.
    @discardableResult
    public mutating func cycleFocus() -> Bool {
        let surfaces = layout.surfaces
        guard surfaces.count > 1,
              let id = focusedSurfaceID,
              let index = surfaces.firstIndex(where: { $0.id == id }) else { return false }
        focusedSurfaceID = surfaces[(index + 1) % surfaces.count].id
        return true
    }

    /// Toggle zoom: zoom the focused pane, or unzoom if any pane is zoomed.
    /// False when there's nothing to zoom (single pane / no focus).
    @discardableResult
    public mutating func toggleZoom() -> Bool {
        if zoomedSurfaceID != nil, zoomedSurfaceID == focusedSurfaceID {
            zoomedSurfaceID = nil
            return true
        }
        guard layout.surfaces.count > 1, let id = focusedSurfaceID else { return false }
        zoomedSurfaceID = id
        return true
    }
}
