import Foundation
import Testing
@testable import ZettyCore

// A repo's .zetty/project.json is someone else's file. Read without limits,
// a symlink to /dev/zero read forever on the main thread before any prompt
// could appear (pre-release sweep, 2026-11-14).

private func repo(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".zetty"),
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

@Test func anOversizedProjectFileIsIgnored() throws {
    try repo { root in
        let padding = String(repeating: " ", count: ProjectFileIO.maxBytes)
        try Data(("{" + padding + "\"schemaVersion\": 1}").utf8)
            .write(to: ProjectFileIO.url(forProjectRoot: root.path))
        #expect(ProjectFileIO.load(projectRoot: root.path) == nil)
    }
}

@Test func aProjectFileThatIsADeviceIsIgnored() throws {
    try repo { root in
        try FileManager.default.createSymbolicLink(
            atPath: ProjectFileIO.url(forProjectRoot: root.path).path, withDestinationPath: "/dev/zero")
        #expect(ProjectFileIO.load(projectRoot: root.path) == nil)
    }
}

@Test func aProjectFileLinkedToARegularFileStillLoads() throws {
    try repo { root in
        let real = root.appendingPathComponent("shared.json")
        try Data(#"{"schemaVersion": 1, "startupCommand": "make"}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            atPath: ProjectFileIO.url(forProjectRoot: root.path).path, withDestinationPath: real.path)
        #expect(ProjectFileIO.load(projectRoot: root.path)?.startupCommand == "make")
    }
}
