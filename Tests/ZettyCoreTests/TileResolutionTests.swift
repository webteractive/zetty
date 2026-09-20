import Foundation
import Testing
@testable import ZettyCore

private func tree(_ dir: String) -> PaneTree {
    let surface = Surface(workingDir: dir)
    return PaneTree(layout: Layout(root: .leaf(surface)), focusedSurfaceID: surface.id)
}

private func project(_ root: String, _ trees: [PaneTree]) -> ProjectRuntime {
    ProjectRuntime(name: "zetty", rootPath: root,
                   tabList: TabList(restoring: trees, defaultWorkingDir: root))
}

@Test func aSlotResolvesToItsPane() {
    let t = tree("/tmp/zetty")
    let p = project("/tmp/zetty", [t])
    let profile = TileProfile(name: "m", grid: TilesGrid(columns: 1, rows: 1), slots: [
        TileSlot(projectRoot: "/tmp/zetty", tabID: t.id, label: "zetty / main"),
    ])
    #expect(TileResolution.resolve(profile: profile, projects: [p])
        == [.pane(projectIndex: 0, tabIndex: 0, surfaceID: t.layout.surfaces[0].id)])
}

@Test func aReorderedTabStillResolves() {
    // The whole point of PaneTree.id: the index changed, the identity did not.
    let a = tree("/tmp/zetty")
    let b = tree("/tmp/zetty")
    let p = project("/tmp/zetty", [b, a])
    let profile = TileProfile(name: "m", grid: TilesGrid(columns: 1, rows: 1), slots: [
        TileSlot(projectRoot: "/tmp/zetty", tabID: a.id, label: "zetty / main"),
    ])
    #expect(TileResolution.resolve(profile: profile, projects: [p])
        == [.pane(projectIndex: 0, tabIndex: 1, surfaceID: a.layout.surfaces[0].id)])
}

@Test func aMissingTabKeepsItsRememberedLabel() {
    let p = project("/tmp/zetty", [tree("/tmp/zetty")])
    let profile = TileProfile(name: "m", grid: TilesGrid(columns: 1, rows: 1), slots: [
        TileSlot(projectRoot: "/tmp/zetty", tabID: UUID(), label: "zetty / gone"),
    ])
    #expect(TileResolution.resolve(profile: profile, projects: [p]) == [.missing("zetty / gone")])
}

@Test func aMissingProjectIsAlsoMissingNotEmpty() {
    let profile = TileProfile(name: "m", grid: TilesGrid(columns: 1, rows: 1), slots: [
        TileSlot(projectRoot: "/tmp/removed", tabID: UUID(), label: "removed / api"),
    ])
    #expect(TileResolution.resolve(profile: profile, projects: []) == [.missing("removed / api")])
}

@Test func aHoleResolvesToEmpty() {
    let profile = TileProfile(name: "m", grid: TilesGrid(columns: 2, rows: 1))
    #expect(TileResolution.resolve(profile: profile, projects: []) == [.empty, .empty])
}

@Test func slotPathsAreComparedCanonically() {
    // "/tmp/zetty/" and "/tmp/zetty" are the same project.
    let t = tree("/tmp/zetty")
    let p = project("/tmp/zetty/", [t])
    let profile = TileProfile(name: "m", grid: TilesGrid(columns: 1, rows: 1), slots: [
        TileSlot(projectRoot: "/tmp/zetty", tabID: t.id, label: "zetty / main"),
    ])
    if case .missing = TileResolution.resolve(profile: profile, projects: [p])[0] {
        Issue.record("a trailing slash should not break resolution")
    }
}
