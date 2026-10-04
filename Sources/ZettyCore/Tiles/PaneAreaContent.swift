import Foundation

/// What `rebuildSurfaceNodeView` puts in the pane area. Pure, so the order of
/// precedence is tested rather than implied by the order of `if`s.
public enum PaneAreaContent: Equatable, Sendable {
    case hibernationPlaceholder
    case tileChooser
    case tileGrid
    case panes

    /// Tile mode outranks the active project. The grid spans every project and
    /// never follows the active one, so a hibernated active project must not
    /// swap it for its placeholder: that took the grid out of the window, and
    /// every pane attached to a tile afterwards got a view that was never on
    /// screen — so never a terminal.
    public static func resolve(tileMode: Bool, hasOpenTileViews: Bool,
                               activeProjectHibernated: Bool) -> PaneAreaContent {
        if tileMode { return hasOpenTileViews ? .tileGrid : .tileChooser }
        return activeProjectHibernated ? .hibernationPlaceholder : .panes
    }
}
