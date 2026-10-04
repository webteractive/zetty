import Testing
@testable import ZettyCore

@Test func tileModeShowsTheGridEvenWhenTheActiveProjectIsHibernated() {
    // The grid spans every project and never follows the active one. Letting
    // the active project's hibernation placeholder win took the grid out of
    // the window, so every pane attached to a tile afterwards got a view that
    // was never on screen and never a terminal.
    #expect(PaneAreaContent.resolve(tileMode: true, hasOpenTileViews: true,
                                    activeProjectHibernated: true) == .tileGrid)
    #expect(PaneAreaContent.resolve(tileMode: true, hasOpenTileViews: false,
                                    activeProjectHibernated: true) == .tileChooser)
}

@Test func outsideTileModeTheActiveProjectDecides() {
    #expect(PaneAreaContent.resolve(tileMode: false, hasOpenTileViews: true,
                                    activeProjectHibernated: true) == .hibernationPlaceholder)
    #expect(PaneAreaContent.resolve(tileMode: false, hasOpenTileViews: true,
                                    activeProjectHibernated: false) == .panes)
}

@Test func tileModeWithAnAwakeProjectStillShowsTheGrid() {
    #expect(PaneAreaContent.resolve(tileMode: true, hasOpenTileViews: true,
                                    activeProjectHibernated: false) == .tileGrid)
    #expect(PaneAreaContent.resolve(tileMode: true, hasOpenTileViews: false,
                                    activeProjectHibernated: false) == .tileChooser)
}
