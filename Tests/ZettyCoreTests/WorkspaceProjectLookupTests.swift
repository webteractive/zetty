import Foundation
import Testing
@testable import ZettyCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-root-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func projectIndexForRootMatchesTheSameFolderSpelledDifferently() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let ws = WorkspaceModel()
    ws.addProject(name: "app", rootPath: dir.path, makeActive: false)
    let expected = ws.projects.firstIndex { $0.name == "app" }

    #expect(expected != nil)
    #expect(ws.projectIndex(forRoot: dir.path) == expected)
    #expect(ws.projectIndex(forRoot: dir.path + "/") == expected)
    #expect(ws.projectIndex(forRoot: dir.path + "/sub/..") == expected)
}

@Test func projectIndexForRootResolvesSymlinks() throws {
    let dir = try makeTempDir()
    let link = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
    defer {
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.removeItem(at: dir)
    }
    let ws = WorkspaceModel()
    ws.addProject(name: "app", rootPath: dir.path, makeActive: false)

    #expect(ws.projectIndex(forRoot: link.path) == ws.projects.firstIndex { $0.name == "app" })
}

@Test func projectIndexForRootIsNilForAnUnknownFolder() throws {
    let ws = WorkspaceModel()
    #expect(ws.projectIndex(forRoot: "/definitely/not/a/project/\(UUID().uuidString)") == nil)
}

@Test func projectIndexForRootNeverMatchesAScratchTerminal() {
    // Scratch terminals are rooted at home too; Home is the real project there.
    let ws = WorkspaceModel()
    ws.addScratchProject(makeActive: false)
    let index = ws.projectIndex(forRoot: NSHomeDirectory())

    #expect(index != nil)
    #expect(index.map { ws.projects[$0].isScratch } == false)
    #expect(index.map { ws.projects[$0].isHome } == true)
}
