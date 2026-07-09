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

@Test func moveTabReordersAndFollowsTheActiveTab() {
    let list = TabList()
    list.newTab(); list.newTab()                       // 3 tabs, active = 2
    let ids = list.trees.map { $0.layout.surfaces[0].id }

    list.moveTab(from: 2, to: 0)                       // drag the active tab to the front
    #expect(list.trees.map { $0.layout.surfaces[0].id } == [ids[2], ids[0], ids[1]])
    #expect(list.activeIndex == 0)

    list.moveTab(from: 1, to: 2)                       // move a non-active tab away
    #expect(list.trees.map { $0.layout.surfaces[0].id } == [ids[2], ids[1], ids[0]])
    #expect(list.activeIndex == 0)

    list.select(index: 1)
    list.moveTab(from: 2, to: 0)                       // a tab crosses the active one
    #expect(list.trees.map { $0.layout.surfaces[0].id } == [ids[0], ids[2], ids[1]])
    #expect(list.activeIndex == 2)                     // still the same logical tab

    list.moveTab(from: 5, to: 0)                       // out of range → no-op
    list.moveTab(from: 1, to: 1)                       // same slot → no-op
    #expect(list.trees.count == 3)
    #expect(list.activeIndex == 2)
}

// MARK: - Break pane into tab

/// Build a fresh 2-pane active tab (focused = the second, newly split pane).
private func twoPaneTabList() -> TabList {
    let list = TabList(defaultWorkingDir: "/tmp/proj")
    var tree = list.activeTree
    _ = tree.splitFocused(direction: .vertical,
                          newSurface: Surface(workingDir: "/tmp/proj"))
    list.activeTree = tree
    return list
}

@Test func breakMovesFocusedPaneIntoNewAdjacentTab() {
    let list = twoPaneTabList()
    let movedID = list.activeTree.focusedSurfaceID!
    let sourceIndex = list.activeIndex

    #expect(list.breakFocusedPaneIntoNewTab() == true)

    #expect(list.trees.count == 2)
    #expect(list.activeIndex == sourceIndex + 1)          // inserted right after
    // New tab is a single pane holding the SAME surface id (live view survives).
    #expect(list.activeTree.layout.surfaces.map(\.id) == [movedID])
    #expect(list.activeTree.focusedSurfaceID == movedID)
    // Source tab collapsed to its remaining pane and no longer holds the moved id.
    #expect(list.trees[sourceIndex].layout.surfaces.contains { $0.id == movedID } == false)
    #expect(list.trees[sourceIndex].layout.surfaces.count == 1)
    #expect(list.trees[sourceIndex].focusedSurfaceID != nil)
}

@Test func breakIsNoOpOnSinglePaneTab() {
    let list = TabList(defaultWorkingDir: "/tmp/proj")   // one pane
    #expect(list.breakFocusedPaneIntoNewTab() == false)
    #expect(list.trees.count == 1)
    #expect(list.activeIndex == 0)
}

@Test func breakClearsSourceZoomAndYieldsUnzoomedTab() {
    let list = twoPaneTabList()
    var tree = list.activeTree
    _ = tree.toggleZoom()                                 // zoom the focused pane
    list.activeTree = tree
    #expect(list.activeTree.zoomedSurfaceID != nil)

    #expect(list.breakFocusedPaneIntoNewTab() == true)

    #expect(list.activeTree.zoomedSurfaceID == nil)        // new tab unzoomed
    let sourceIndex = list.activeIndex - 1
    #expect(list.trees[sourceIndex].zoomedSurfaceID == nil) // source zoom cleared
}

@Test func replaceTreesSwapsTabSetAndClampsActive() {
    let list = TabList(defaultWorkingDir: "/tmp/a")
    list.newTab()                                    // 2 tabs, active = 1
    let replacement = TabList(defaultWorkingDir: "/tmp/b")
    list.replaceTrees(from: replacement)
    #expect(list.trees.count == 1)
    #expect(list.activeIndex == 0)
    #expect(list.activeTree.layout.surfaces.first?.workingDir == "/tmp/b")
    // Replacing from an empty list is impossible by construction (TabList is
    // never empty), so no empty-guard case to test.
}

// MARK: - Background structural ops (CLI no-focus-steal)

@Test func newBackgroundTabDoesNotChangeActiveIndex() {
    let list = TabList(defaultWorkingDir: "/tmp")
    let priorActive = list.activeIndex
    let newID = list.newBackgroundTab()
    #expect(list.trees.count == 2)
    #expect(list.activeIndex == priorActive)             // visible tab unchanged
    #expect(list.trees[1].layout.surfaces.contains { $0.id == newID })
}

@Test func splitPaneKeepsFocusOnOriginalPane() {
    let original = Surface(workingDir: "/tmp")
    var tree = PaneTree(layout: Layout(root: .leaf(original)), focusedSurfaceID: original.id)
    let added = Surface(workingDir: "/tmp")
    let newID = tree.splitPane(original.id, direction: .vertical, newSurface: added)
    #expect(newID == added.id)
    #expect(tree.layout.surfaces.count == 2)
    #expect(tree.focusedSurfaceID == original.id)        // focus did NOT move to the new pane
}

@Test func splitPaneInBackgroundTreeWritesBack() {
    let list = TabList(defaultWorkingDir: "/tmp")
    _ = list.newBackgroundTab()                          // tab index 1, not active
    let target = list.trees[1].focusedSurfaceID!
    let added = Surface(workingDir: "/tmp")
    let newID = list.splitPane(inTreeAt: 1, paneID: target, direction: .horizontal, newSurface: added)
    #expect(newID == added.id)
    #expect(list.trees[1].layout.surfaces.count == 2)
    #expect(list.activeIndex == 0)                       // visible tab still 0
}

@Test func breakPaneToNewTabKeepsCurrentTabVisible() {
    let first = Surface(workingDir: "/tmp")
    var tree = PaneTree(layout: Layout(root: .leaf(first)), focusedSurfaceID: first.id)
    let added = Surface(workingDir: "/tmp")
    _ = tree.splitPane(first.id, direction: .vertical, newSurface: added)
    let list = TabList(restoring: [tree], activeIndex: 0)!  // one tab, two panes
    let movedID = list.breakPaneToNewTab(inTreeAt: 0, paneID: added.id)
    #expect(movedID == added.id)
    #expect(list.trees.count == 2)                       // new tab inserted
    #expect(list.activeIndex == 0)                       // still viewing the source tab
    #expect(list.trees[1].layout.surfaces.map(\.id) == [added.id])
}

@Test func breakPaneToNewTabRejectsSolePane() {
    let list = TabList(defaultWorkingDir: "/tmp")        // single tab, single pane
    let only = list.trees[0].focusedSurfaceID!
    #expect(list.breakPaneToNewTab(inTreeAt: 0, paneID: only) == nil)
}

@Test func addScratchProjectBackgroundKeepsActive() {
    let ws = WorkspaceModel(restoring: [ProjectRuntime(name: "a", rootPath: "/a")])!
    _ = ws.addScratchProject(makeActive: false)
    #expect(ws.activeIndex == 0)                         // active project unchanged
    #expect(ws.projects.contains { $0.isScratch })
}
