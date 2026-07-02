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
