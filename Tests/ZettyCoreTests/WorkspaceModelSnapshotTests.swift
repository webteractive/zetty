import Testing
@testable import ZettyCore
import Foundation

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func workspaceModelRoundTripsThroughStore() throws {
    let model = WorkspaceModel()                                   // project 0 = home
    let p = model.addProject(name: "web", rootPath: "/tmp/web")    // project 1
    p.isPinned = true
    // give project 1 a split in its first tab
    let s2 = Surface(workingDir: "/tmp/web/api")
    _ = p.tabList.activeTree.splitFocused(direction: .vertical, newSurface: s2)
    model.select(index: 0)

    let store = WorkspaceStore(directory: try tempDir())
    try store.save(SessionSnapshot.workspace(from: model))

    let restored = SessionSnapshot.projectRuntimes(from: try store.load())
    #expect(restored.count == 2)
    #expect(restored[1].name == "web")
    #expect(restored[1].rootPath == "/tmp/web")
    #expect(restored[1].isPinned == true)
    let webDirs = restored[1].tabList.trees[0].layout.surfaces.map(\.workingDir)
    #expect(webDirs.contains("/tmp/web/api"))
}

@Test func projectRuntimesFromEmptyWorkspaceIsEmpty() {
    #expect(SessionSnapshot.projectRuntimes(from: Workspace()).isEmpty)
}

@Test func restoredProjectSpawnsNewTabsInProjectRoot() throws {
    let model = WorkspaceModel()
    _ = model.addProject(name: "web", rootPath: "/tmp/web")

    let store = WorkspaceStore(directory: try tempDir())
    try store.save(SessionSnapshot.workspace(from: model))

    let restored = SessionSnapshot.projectRuntimes(from: try store.load())
    let web = try #require(restored.first { $0.name == "web" })
    web.tabList.newTab()
    let newTabDir = web.tabList.activeTree.layout.surfaces.first?.workingDir
    #expect(newTabDir == "/tmp/web")
}

@Test func workspaceRoundTripPreservesActiveProjectIndex() throws {
    let model = WorkspaceModel()
    _ = model.addProject(name: "web", rootPath: "/tmp/web")
    let webIndex = try #require(model.projects.firstIndex { $0.name == "web" })
    model.select(index: webIndex)

    let store = WorkspaceStore(directory: try tempDir())
    try store.save(SessionSnapshot.workspace(from: model))

    let workspace = try store.load()
    #expect(workspace.activeProjectIndex == webIndex)

    let restored = WorkspaceModel(
        restoring: SessionSnapshot.projectRuntimes(from: workspace),
        activeIndex: workspace.activeProjectIndex
    )
    #expect(restored?.activeProject.name == "web")
}

@Test func legacyWorkspaceJSONWithoutActiveIndexDecodesToZero() throws {
    let json = Data(#"{"schemaVersion":1,"projects":[]}"#.utf8)
    let workspace = try JSONDecoder().decode(Workspace.self, from: json)
    #expect(workspace.activeProjectIndex == 0)
}

@Test func legacyWorkspaceJSONDefaultsSidebarState() throws {
    let json = Data(#"{"schemaVersion":1,"projects":[]}"#.utf8)
    let workspace = try JSONDecoder().decode(Workspace.self, from: json)
    #expect(workspace.sidebarCollapsed == false)
    #expect(workspace.sidebarWidth == SidebarMetrics.defaultWidth)
}

@Test func workspaceRoundTripPreservesActiveTabAndFocusedPane() throws {
    let model = WorkspaceModel()
    let project = model.activeProject
    project.tabList.newTab()                                  // 2 tabs, active = tab 1
    let s2 = Surface(workingDir: "/tmp/x")
    _ = project.tabList.activeTree.splitFocused(direction: .vertical, newSurface: s2)  // focus lands on s2

    let store = WorkspaceStore(directory: try tempDir())
    try store.save(SessionSnapshot.workspace(from: model))

    let restored = SessionSnapshot.projectRuntimes(from: try store.load())
    #expect(restored[0].tabList.activeIndex == 1)
    #expect(restored[0].tabList.activeTree.focusedSurfaceID == s2.id)
    // The single-pane first tab still focuses its only surface.
    #expect(restored[0].tabList.trees[0].focusedSurfaceID != nil)
}

@Test func legacySessionJSONDefaultsActiveTabToZero() throws {
    let json = Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"main","tabs":[]}"#.utf8)
    let session = try JSONDecoder().decode(Session.self, from: json)
    #expect(session.activeTabIndex == 0)
}

@Test func workspaceRoundTripsSidebarState() throws {
    var workspace = Workspace()
    workspace.sidebarCollapsed = true
    workspace.sidebarWidth = 320
    let store = WorkspaceStore(directory: try tempDir())
    try store.save(workspace)
    let loaded = try store.load()
    #expect(loaded.sidebarCollapsed == true)
    #expect(loaded.sidebarWidth == 320)
}

@Test func projectIDsSurviveARelaunch() throws {
    // Another Mac's viewer opens a project by this id; a fresh one per launch
    // made every open remote project read "isn't open … any more" after this
    // Mac relaunched, and reshuffled its sidebar colors.
    let model = WorkspaceModel()
    let web = model.addProject(name: "web", rootPath: "/tmp/web")
    let store = WorkspaceStore(directory: try tempDir())
    try store.save(SessionSnapshot.workspace(from: model))

    let restored = SessionSnapshot.projectRuntimes(from: try store.load())
    #expect(restored.map(\.id) == [model.projects[0].id, web.id])
}
