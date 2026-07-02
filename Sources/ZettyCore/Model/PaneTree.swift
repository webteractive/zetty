import Foundation

public struct PaneTree: Codable, Sendable, Equatable {
    public var layout: Layout
    public var focusedSurfaceID: UUID?
    public var manualTitle: String?

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
    @discardableResult
    public mutating func splitFocused(direction: SplitDirection, newSurface: Surface, ratio: Double = 0.5) -> Bool {
        guard let id = focusedSurfaceID else { return false }
        guard layout.split(surfaceID: id, direction: direction, newSurface: newSurface, ratio: ratio) else { return false }
        focusedSurfaceID = newSurface.id
        return true
    }

    /// Close the focused leaf; focus moves to the first remaining surface. False if it was the only one.
    @discardableResult
    public mutating func closeFocused() -> Bool {
        guard let id = focusedSurfaceID else { return false }
        guard layout.close(surfaceID: id) else { return false }
        focusedSurfaceID = layout.surfaces.first?.id
        return true
    }

    /// Focus the surface with `id`; no-op if it isn't in the tree.
    public mutating func focus(_ id: UUID) {
        guard layout.surfaces.contains(where: { $0.id == id }) else { return }
        focusedSurfaceID = id
    }
}
