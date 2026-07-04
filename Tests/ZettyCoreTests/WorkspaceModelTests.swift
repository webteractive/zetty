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

@Test func projectsSortByNameCaseInsensitive() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "Zeta", rootPath: "/z"),
        ProjectRuntime(name: "alpha", rootPath: "/a"),
        ProjectRuntime(name: "Beta", rootPath: "/b"),
    ], activeIndex: 0)!
    #expect(ws.projects.map(\.name) == ["alpha", "Beta", "Zeta"])
}

@Test func pinnedProjectsSortAboveUnpinnedEachByName() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "delta", rootPath: "/d"),
        ProjectRuntime(name: "alpha", rootPath: "/a", isPinned: true),
        ProjectRuntime(name: "charlie", rootPath: "/c"),
        ProjectRuntime(name: "bravo", rootPath: "/b", isPinned: true),
    ], activeIndex: 0)!
    #expect(ws.projects.map(\.name) == ["alpha", "bravo", "charlie", "delta"])
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

@Test func addProjectInsertsInSortedPositionAndStaysActive() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "alpha", rootPath: "/a"),
        ProjectRuntime(name: "zeta", rootPath: "/z"),
    ], activeIndex: 0)!
    let m = ws.addProject(name: "mike", rootPath: "/m")
    #expect(ws.projects.map(\.name) == ["alpha", "mike", "zeta"])
    #expect(ws.activeProject.id == m.id)             // active follows the new project
    #expect(ws.activeIndex == 1)
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

@Test func renameProjectResortsAndKeepsActiveIdentity() {
    let model = WorkspaceModel()
    let zebra = model.addProject(name: "zebra", rootPath: "/tmp/zebra")
    model.addProject(name: "alpha", rootPath: "/tmp/alpha")
    // Active is "alpha" (last added). Rename zebra → "aaa": it must sort first
    // while the active project stays "alpha" by identity.
    guard let zebraIndex = model.projects.firstIndex(where: { $0 === zebra }) else {
        Issue.record("zebra missing"); return
    }
    model.rename(projectAt: zebraIndex, to: "aaa")
    #expect(model.projects.first?.name == "aaa")
    #expect(model.activeProject.name == "alpha")
    // Out-of-range index is a no-op.
    model.rename(projectAt: 99, to: "nope")
}
