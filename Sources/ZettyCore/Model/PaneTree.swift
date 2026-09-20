import Foundation

public struct PaneTree: Codable, Sendable, Equatable {
    /// Stable identity for this tab, so a tile-profile slot can point at it.
    /// Decoded tolerantly and minted when absent — neither of the things that
    /// identify a tab today will do as a key: display titles are regenerated
    /// from the running agent every second, and indices shift on reorder.
    public var id: UUID = UUID()
    public var layout: Layout
    public var focusedSurfaceID: UUID?
    public var manualTitle: String?
    /// Zoomed (temporarily maximized) pane, if any. Transient by design —
    /// excluded from `CodingKeys` so it never persists to `workspace.json`,
    /// matching tmux's zoom semantics.
    public var zoomedSurfaceID: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, layout, focusedSurfaceID, manualTitle
    }

    public init(layout: Layout, focusedSurfaceID: UUID? = nil,
                manualTitle: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.layout = layout
        self.focusedSurfaceID = focusedSurfaceID
        self.manualTitle = manualTitle
    }

    /// Hand-written so a `workspace.json` from before tile profiles — which has
    /// no `id` — loads and mints one instead of throwing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.layout = try container.decode(Layout.self, forKey: .layout)
        self.focusedSurfaceID = try container.decodeIfPresent(UUID.self,
                                                              forKey: .focusedSurfaceID)
        self.manualTitle = try container.decodeIfPresent(String.self, forKey: .manualTitle)
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

    /// Swaps the pane `id` for `replacement` in the same slot, carrying focus
    /// and zoom across to the new surface.
    ///
    /// Rewriting `focusedSurfaceID` and `zoomedSurfaceID` is the load-bearing
    /// part: both hold the OLD uuid, and a zoom left pointing at a leaf that no
    /// longer exists makes the pane disappear entirely.
    @discardableResult
    public mutating func replaceSurface(_ id: UUID, with replacement: Surface) -> Bool {
        guard layout.replace(surfaceID: id, with: replacement) else { return false }
        if focusedSurfaceID == id { focusedSurfaceID = replacement.id }
        if zoomedSurfaceID == id { zoomedSurfaceID = replacement.id }
        return true
    }

    /// Splits the pane `id` (regardless of current focus) and restores focus to
    /// whatever pane was focused before — so a background split never moves the
    /// keyboard focus. Returns `newSurface.id`, or nil when `id` is not present.
    @discardableResult
    public mutating func splitPane(_ id: UUID, direction: SplitDirection, newSurface: Surface, ratio: Double = 0.5) -> UUID? {
        guard layout.surfaces.contains(where: { $0.id == id }) else { return nil }
        let priorFocus = focusedSurfaceID
        focus(id)
        guard splitFocused(direction: direction, newSurface: newSurface, ratio: ratio) else { return nil }
        if let priorFocus, layout.surfaces.contains(where: { $0.id == priorFocus }) {
            focus(priorFocus)
        }
        return newSurface.id
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
