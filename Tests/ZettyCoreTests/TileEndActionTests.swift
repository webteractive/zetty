import Testing
@testable import ZettyCore

@Test func tileEndActionClosesThePaneWhileItsTabHasOthers() {
    #expect(TileEndAction.resolve(panesInTab: 2, tabsInProject: 1, canHibernate: true) == .closePane)
    #expect(TileEndAction.resolve(panesInTab: 3, tabsInProject: 4, canHibernate: false) == .closePane)
}

@Test func tileEndActionClosesTheTabForItsOnlyPane() {
    #expect(TileEndAction.resolve(panesInTab: 1, tabsInProject: 2, canHibernate: true) == .closeTab)
    #expect(TileEndAction.resolve(panesInTab: 1, tabsInProject: 2, canHibernate: false) == .closeTab)
}

@Test func tileEndActionHibernatesAProjectsOnlyPane() {
    // The last pane of a project cannot be closed, so the session ends by
    // putting the project to sleep, which keeps its layout.
    #expect(TileEndAction.resolve(panesInTab: 1, tabsInProject: 1, canHibernate: true) == .hibernateProject)
}

@Test func tileEndActionOffersNothingWhereTheOnlyPaneCannotHibernate() {
    // Home, a scratch terminal, a project already dormant.
    #expect(TileEndAction.resolve(panesInTab: 1, tabsInProject: 1, canHibernate: false) == nil)
}

@Test func tileEndActionNamesWhatItWillDo() {
    #expect(TileEndAction.closePane.symbol == TileEndAction.closeTab.symbol)
    #expect(TileEndAction.hibernateProject.symbol != TileEndAction.closePane.symbol)
    #expect(TileEndAction.hibernateProject.tooltip.contains("Hibernate"))
    #expect(TileEndAction.closeTab.confirmationSubject == "Tab")
}
