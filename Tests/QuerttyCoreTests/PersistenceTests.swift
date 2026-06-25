import Testing
import Foundation
@testable import QuerttyCore

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("quertty-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func loadingMissingWorkspaceReturnsEmpty() throws {
    let store = WorkspaceStore(directory: try tempDir())
    let ws = try store.load()
    #expect(ws.projects.isEmpty)
    #expect(ws.schemaVersion == 1)
}

@Test func saveThenLoadRoundTrips() throws {
    let dir = try tempDir()
    let store = WorkspaceStore(directory: dir)

    let surface = Surface(workingDir: "/tmp/proj", command: "claude")
    let tab = Tab(title: "main", layout: Layout(root: .leaf(surface)))
    let session = Session(title: "work", tabs: [tab])
    let project = Project(name: "demo", rootPath: "/tmp/proj",
                          isPinned: true, sessions: [session])
    let original = Workspace(schemaVersion: 1, projects: [project])

    try store.save(original)
    let restored = try store.load()

    #expect(restored == original)
}

@Test func loadingCorruptFileThrows() throws {
    let dir = try tempDir()
    let url = dir.appendingPathComponent("workspace.json")
    try "not json".write(to: url, atomically: true, encoding: .utf8)
    let store = WorkspaceStore(directory: dir)
    #expect(throws: (any Error).self) {
        try store.load()
    }
}
