import Testing
import Foundation
@testable import QuerttyCore

// MARK: - Helpers

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("quertty-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Round-trip tests

/// Build a two-tab TabList (one with a horizontal split), persist it, reload
/// it, and verify that tab count and each surface's workingDir survive.
@Test func roundTripTabsAndSplitsThroughWorkspaceStore() throws {
    // ── Arrange ──────────────────────────────────────────────────────────────
    let dir = try tempDir()
    let store = WorkspaceStore(directory: dir)

    // Tab 1: single surface at /home
    let surf1 = Surface(workingDir: "/home")
    var layout1 = Layout(root: .leaf(surf1))

    // Tab 2: horizontal split — /alpha (left) / /beta (right)
    let surfA = Surface(workingDir: "/alpha")
    let surfB = Surface(workingDir: "/beta")
    var layout2 = Layout(root: .leaf(surfA))
    layout2.split(surfaceID: surfA.id, direction: .horizontal, newSurface: surfB)

    let tree1 = PaneTree(layout: layout1, focusedSurfaceID: surf1.id)
    let tree2 = PaneTree(layout: layout2, focusedSurfaceID: surfA.id)

    let tabList = TabList(restoring: [tree1, tree2])!

    // ── Act ───────────────────────────────────────────────────────────────────
    let workspace = SessionSnapshot.workspace(from: tabList)
    try store.save(workspace)
    let reloaded = try store.load()
    let restoredTrees = SessionSnapshot.paneTrees(from: reloaded)

    // ── Assert ─────────────────────────────────────────────────────────────
    #expect(restoredTrees.count == 2)

    let dirs0 = restoredTrees[0].layout.surfaces.map(\.workingDir)
    #expect(dirs0 == ["/home"])

    let dirs1 = restoredTrees[1].layout.surfaces.map(\.workingDir)
    #expect(dirs1.contains("/alpha"))
    #expect(dirs1.contains("/beta"))
}

/// Loading an absent workspace file yields an empty tree list so callers
/// fall back to a fresh single-tab layout without crashing.
@Test func emptyWorkspaceYieldsNoTrees() throws {
    let dir = try tempDir()
    let store = WorkspaceStore(directory: dir)
    let workspace = try store.load()
    let trees = SessionSnapshot.paneTrees(from: workspace)
    #expect(trees.isEmpty)
}

/// A Workspace with no sessions (just an empty project) also yields no trees.
@Test func workspaceWithNoSessionsYieldsNoTrees() {
    let project = Project(name: "empty", rootPath: "/", sessions: [])
    let workspace = Workspace(projects: [project])
    let trees = SessionSnapshot.paneTrees(from: workspace)
    #expect(trees.isEmpty)
}

/// A Workspace with a project whose session has no tabs yields no trees.
@Test func workspaceWithEmptySessionYieldsNoTrees() {
    let session = Session(title: "s", tabs: [])
    let project = Project(name: "p", rootPath: "/", sessions: [session])
    let workspace = Workspace(projects: [project])
    let trees = SessionSnapshot.paneTrees(from: workspace)
    #expect(trees.isEmpty)
}

/// `TabList.init?(restoring:)` returns nil for an empty array.
@Test func restoringInitReturnsNilForEmptyArray() {
    #expect(TabList(restoring: []) == nil)
}

/// `TabList.init?(restoring:)` produces the correct tree count and respects activeIndex.
@Test func restoringInitBuildsCorrectTabList() {
    let s1 = Surface(workingDir: "/one")
    let s2 = Surface(workingDir: "/two")
    let t1 = PaneTree(layout: Layout(root: .leaf(s1)), focusedSurfaceID: s1.id)
    let t2 = PaneTree(layout: Layout(root: .leaf(s2)), focusedSurfaceID: s2.id)

    let tabs = TabList(restoring: [t1, t2], activeIndex: 1)
    #expect(tabs != nil)
    #expect(tabs?.trees.count == 2)
    #expect(tabs?.activeIndex == 1)
}

/// `activeIndex` is clamped when out of range.
@Test func restoringInitClampsOutOfRangeActiveIndex() {
    let s = Surface(workingDir: "/x")
    let t = PaneTree(layout: Layout(root: .leaf(s)), focusedSurfaceID: s.id)
    let tabs = TabList(restoring: [t], activeIndex: 99)
    #expect(tabs?.activeIndex == 0)
}

/// `manualTitle` is persisted and restored across save→load cycles.
@Test func manualTitleRoundTripsThroughWorkspaceStore() throws {
    // ── Arrange ──────────────────────────────────────────────────────────────
    let dir = try tempDir()
    let store = WorkspaceStore(directory: dir)

    // Tab 1: with manual title
    let surf1 = Surface(workingDir: "/home")
    var tree1 = PaneTree(layout: Layout(root: .leaf(surf1)), focusedSurfaceID: surf1.id)
    tree1.manualTitle = "My Custom Tab"

    // Tab 2: no manual title (will restore as nil)
    let surf2 = Surface(workingDir: "/work")
    let tree2 = PaneTree(layout: Layout(root: .leaf(surf2)), focusedSurfaceID: surf2.id)

    let tabList = TabList(restoring: [tree1, tree2])!

    // ── Act ───────────────────────────────────────────────────────────────────
    let workspace = SessionSnapshot.workspace(from: tabList)
    try store.save(workspace)
    let reloaded = try store.load()
    let restoredTrees = SessionSnapshot.paneTrees(from: reloaded)

    // ── Assert ─────────────────────────────────────────────────────────────
    #expect(restoredTrees.count == 2)
    #expect(restoredTrees[0].manualTitle == "My Custom Tab")
    #expect(restoredTrees[1].manualTitle == nil)
}
