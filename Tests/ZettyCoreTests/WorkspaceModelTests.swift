import Testing
import Foundation
@testable import ZettyCore

@Test func seedsOneActiveProject() {
    let ws = WorkspaceModel()
    #expect(ws.projects.count == 1)
    #expect(ws.activeIndex == 0)
}

@Test func addProjectAppendsAndActivates() {
    let ws = WorkspaceModel()
    let p = ws.addProject(name: "web", rootPath: "/tmp/web")
    #expect(ws.projects.count == 2)
    #expect(ws.activeIndex == 1)
    #expect(ws.activeProject.id == p.id)
    #expect(ws.activeProject.rootPath == "/tmp/web")
}

@Test func eachProjectHasOwnTabList() {
    let ws = WorkspaceModel()
    let a = ws.activeProject.tabList
    _ = ws.addProject(name: "b", rootPath: "/tmp/b")
    let b = ws.activeProject.tabList
    #expect(a !== b)  // distinct TabList instances
}

@Test func removingProjectBeforeActiveStepsBack() {
    // Sorted order is [a, b, c]; active = c at index 2.
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "a", rootPath: "/a"),
        ProjectRuntime(name: "b", rootPath: "/b"),
        ProjectRuntime(name: "c", rootPath: "/c"),
    ], activeIndex: 2)!
    ws.removeProject(at: 0)                         // remove "a" (before active)
    #expect(ws.projects.count == 2)
    #expect(ws.activeIndex == 1)                    // c slid from 2 → 1
}

@Test func restorePreservesManualOrderWithoutAlphabetizing() {
    // Order is manual: restore keeps the given order verbatim (no name sort).
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "Zeta", rootPath: "/z"),
        ProjectRuntime(name: "alpha", rootPath: "/a"),
        ProjectRuntime(name: "Beta", rootPath: "/b"),
    ], activeIndex: 0)!
    #expect(ws.projects.map(\.name) == ["Zeta", "alpha", "Beta"])
}

@Test func restorePartitionsPinnedFirstPreservingRelativeOrder() {
    // Pinned-first is the only invariant; within each group the given order
    // (not name order) is preserved.
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "delta", rootPath: "/d"),
        ProjectRuntime(name: "alpha", rootPath: "/a", isPinned: true),
        ProjectRuntime(name: "charlie", rootPath: "/c"),
        ProjectRuntime(name: "bravo", rootPath: "/b", isPinned: true),
    ], activeIndex: 0)!
    #expect(ws.projects.map(\.name) == ["alpha", "bravo", "delta", "charlie"])
    #expect(ws.projects.map(\.isPinned) == [true, true, false, false])
}

@Test func togglePinMovesProjectAboveUnpinnedAndKeepsActive() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "alpha", rootPath: "/a"),
        ProjectRuntime(name: "zeta", rootPath: "/z"),
    ], activeIndex: 1)!                             // active = zeta
    let zetaIdx = ws.projects.firstIndex { $0.name == "zeta" }!
    ws.togglePin(at: zetaIdx)                        // pin zeta → jumps above alpha
    #expect(ws.projects.map(\.name) == ["zeta", "alpha"])
    #expect(ws.activeProject.name == "zeta")         // active preserved by identity
}

@Test func addProjectAppendsToEndOfGroupAndStaysActive() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "alpha", rootPath: "/a"),
        ProjectRuntime(name: "zeta", rootPath: "/z"),
    ], activeIndex: 0)!
    let m = ws.addProject(name: "mike", rootPath: "/m")
    #expect(ws.projects.map(\.name) == ["alpha", "zeta", "mike"])  // appended, not sorted
    #expect(ws.activeProject.id == m.id)             // active follows the new project
    #expect(ws.activeIndex == 2)
}

@Test func addProjectInBackgroundKeepsActiveProject() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "alpha", rootPath: "/a"),
        ProjectRuntime(name: "zeta", rootPath: "/z"),
    ], activeIndex: 0)!
    let activeBefore = ws.activeProject.id
    let m = ws.addProject(name: "mike", rootPath: "/m", makeActive: false)
    #expect(ws.projects.map(\.name) == ["alpha", "zeta", "mike"])  // appended to end
    #expect(ws.activeProject.id == activeBefore)                    // active did NOT switch
    #expect(ws.projects.contains { $0.id == m.id })
}

@Test func addProjectAppendsBelowPinnedGroup() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "alpha", rootPath: "/a", isPinned: true),
        ProjectRuntime(name: "zeta", rootPath: "/z"),
    ], activeIndex: 0)!
    _ = ws.addProject(name: "mike", rootPath: "/m", makeActive: false)
    // New project is unpinned → lands after the pinned group, at the end.
    #expect(ws.projects.map(\.name) == ["alpha", "zeta", "mike"])
    #expect(ws.projects.map(\.isPinned) == [true, false, false])
}

@Test func moveProjectReordersWithinGroupPreservingActive() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "a", rootPath: "/a"),
        ProjectRuntime(name: "b", rootPath: "/b"),
        ProjectRuntime(name: "c", rootPath: "/c"),
    ], activeIndex: 1)!                              // active = b
    ws.moveProject(from: 0, to: 2)                   // a moves to the end
    #expect(ws.projects.map(\.name) == ["b", "c", "a"])
    #expect(ws.activeProject.name == "b")            // active preserved by identity
}

@Test func moveProjectRejectsCrossGroupMove() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "p", rootPath: "/p", isPinned: true),
        ProjectRuntime(name: "u", rootPath: "/u"),
    ], activeIndex: 0)!
    ws.moveProject(from: 1, to: 0)                   // unpinned → into pinned slot: rejected
    #expect(ws.projects.map(\.name) == ["p", "u"])   // unchanged
    #expect(ws.projects.map(\.isPinned) == [true, false])
}

@Test func togglePinAppendsToBottomOfPinnedGroup() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "a", rootPath: "/a", isPinned: true),
        ProjectRuntime(name: "b", rootPath: "/b", isPinned: true),
        ProjectRuntime(name: "c", rootPath: "/c"),
    ], activeIndex: 0)!
    let cIdx = ws.projects.firstIndex { $0.name == "c" }!
    ws.togglePin(at: cIdx)                            // pin c → bottom of pinned group
    #expect(ws.projects.map(\.name) == ["a", "b", "c"])
    #expect(ws.projects.map(\.isPinned) == [true, true, true])
}

@Test func removingLastRemainingProjectIsNoOp() {
    let ws = WorkspaceModel()
    ws.removeProject(at: 0)
    #expect(ws.projects.count == 1)
}

@Test func togglePinFlips() {
    let ws = WorkspaceModel()
    #expect(ws.projects[0].isPinned == false)
    ws.togglePin(at: 0)
    #expect(ws.projects[0].isPinned == true)
}

@Test func workspaceSelectIgnoresOutOfRange() {
    let ws = WorkspaceModel()
    ws.select(index: 5)
    #expect(ws.activeIndex == 0)
}

@Test func removingActiveMiddleProjectLandsOnNext() {
    let ws = WorkspaceModel()
    _ = ws.addProject(name: "b", rootPath: "/b")
    _ = ws.addProject(name: "c", rootPath: "/c")   // 3 projects, active = 2
    ws.select(index: 1)                              // make the middle project active
    ws.removeProject(at: 1)                          // remove the active (non-last) project
    #expect(ws.projects.count == 2)
    #expect(ws.activeIndex == 1)                     // next project slid into place
}

@Test func removingActiveLastProjectClamps() {
    let ws = WorkspaceModel()
    _ = ws.addProject(name: "b", rootPath: "/b")     // 2 projects, active = 1 (last)
    ws.removeProject(at: 1)
    #expect(ws.projects.count == 1)
    #expect(ws.activeIndex == 0)
}

@Test func restoringClampsActiveIndex() {
    let trees = [ProjectRuntime(name: "a", rootPath: "/a"),
                 ProjectRuntime(name: "b", rootPath: "/b")]
    let high = WorkspaceModel(restoring: trees, activeIndex: 99)
    #expect(high?.activeIndex == 1)                  // clamped to last
    let low = WorkspaceModel(restoring: trees, activeIndex: -5)
    #expect(low?.activeIndex == 0)                   // clamped to first
    #expect(WorkspaceModel(restoring: []) == nil)    // nil on empty
}

@Test func projectContainingSurfaceFindsOwner() {
    let model = WorkspaceModel()
    let second = model.addProject(name: "beta", rootPath: "/tmp/beta")
    let surfaceID = second.tabList.trees[0].layout.surfaces[0].id
    #expect(model.project(containing: surfaceID) === second)
    #expect(model.project(containing: UUID()) == nil)
}

@Test func addScratchProjectIsHomeRootedAndActive() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "a", rootPath: "/a"),
    ], activeIndex: 0)!
    let s = ws.addScratchProject()
    #expect(s.isScratch)
    #expect(s.rootPath == NSHomeDirectory())
    #expect(s.name == "scratch")
    #expect(ws.activeProject.id == s.id)          // switches to it
    #expect(ws.projects.map(\.isScratch) == [false, true])  // lands after the regular project
}

@Test func scratchNamesIncrementUniquely() {
    let ws = WorkspaceModel()
    let a = ws.addScratchProject()
    let b = ws.addScratchProject()
    let c = ws.addScratchProject()
    #expect(a.name == "scratch")
    #expect(b.name == "scratch 2")
    #expect(c.name == "scratch 3")
}

@Test func renameDoesNotMoveProject() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "zebra", rootPath: "/z"),
        ProjectRuntime(name: "alpha", rootPath: "/a"),
    ], activeIndex: 1)!                              // active = alpha
    // Manual order: renaming zebra → "aaa" must NOT move it (old behavior sorted).
    ws.rename(projectAt: 0, to: "aaa")
    #expect(ws.projects.map(\.name) == ["aaa", "alpha"])   // position unchanged
    #expect(ws.activeProject.name == "alpha")               // active preserved
    // Out-of-range index is a no-op.
    ws.rename(projectAt: 99, to: "nope")
}
