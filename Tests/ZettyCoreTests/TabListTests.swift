import Testing
@testable import ZettyCore

@Test func startsWithOneActiveTab() {
    let tabs = TabList()
    #expect(tabs.trees.count == 1)
    #expect(tabs.activeIndex == 0)
}

@Test func newTabAppendsAndActivates() {
    let tabs = TabList()
    tabs.newTab()
    #expect(tabs.trees.count == 2)
    #expect(tabs.activeIndex == 1)
}

@Test func eachTabHasIndependentTree() {
    let tabs = TabList()
    let firstID = tabs.trees[0].focusedSurfaceID
    tabs.newTab()
    let secondID = tabs.trees[1].focusedSurfaceID
    #expect(firstID != secondID)  // distinct fresh surfaces
}

@Test func closingLastRemainingTabIsNoOp() {
    let tabs = TabList()
    tabs.closeTab(at: 0)
    #expect(tabs.trees.count == 1)
    #expect(tabs.activeIndex == 0)
}

@Test func closingTabBeforeActiveStepsActiveBack() {
    let tabs = TabList()
    tabs.newTab(); tabs.newTab()        // 3 tabs, active = 2
    tabs.closeTab(at: 0)                 // remove a tab before the active one
    #expect(tabs.trees.count == 2)
    #expect(tabs.activeIndex == 1)       // same logical tab, rebased
}

@Test func closingActiveLastTabClampsActive() {
    let tabs = TabList()
    tabs.newTab()                        // 2 tabs, active = 1 (the last)
    tabs.closeTab(at: 1)
    #expect(tabs.trees.count == 1)
    #expect(tabs.activeIndex == 0)       // clamped into range
}

@Test func closingActiveMiddleTabLandsOnNext() {
    let tabs = TabList()
    tabs.newTab(); tabs.newTab()        // 3 tabs, active = 2
    tabs.select(index: 1)                // make the middle tab active
    tabs.closeTab(at: 1)                 // close the active (non-last) tab
    #expect(tabs.trees.count == 2)
    #expect(tabs.activeIndex == 1)       // stays in place -> the tab that slid in
}

@Test func closeOutOfRangeIsNoOp() {
    let tabs = TabList()
    tabs.newTab()                        // 2 tabs
    tabs.closeTab(at: 9)
    #expect(tabs.trees.count == 2)
}

@Test func selectNextAndPreviousWrap() {
    let tabs = TabList()
    tabs.newTab(); tabs.newTab()        // 3 tabs, active = 2
    tabs.selectNext()                    // wraps 2 -> 0
    #expect(tabs.activeIndex == 0)
    tabs.selectPrevious()                // wraps 0 -> 2
    #expect(tabs.activeIndex == 2)
}

@Test func selectIgnoresOutOfRange() {
    let tabs = TabList()
    tabs.select(index: 5)
    #expect(tabs.activeIndex == 0)
}

@Test func titleIsOneBased() {
    let tabs = TabList()
    #expect(tabs.title(at: 0) == "Tab 1")
    #expect(tabs.title(at: 2) == "Tab 3")
}
