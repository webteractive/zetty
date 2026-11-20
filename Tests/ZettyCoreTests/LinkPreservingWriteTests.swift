import Testing
import Foundation
@testable import ZettyCore

private func scratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-linkwrite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A settings file kept in a dotfiles repo and linked into ~/.claude: hook
/// repair rewrote it at launch with an atomic write, which replaced the link
/// with a plain file and left the dotfiles copy behind (review, 2026-11-20).
@Test func aWriteThroughASymlinkUpdatesItsTargetAndKeepsTheLink() throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("dotfiles-settings.json")
    let link = dir.appendingPathComponent("settings.json")
    try Data("old".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    try LinkPreservingWrite.write(Data("new".utf8), to: link)

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    #expect(try String(contentsOf: target, encoding: .utf8) == "new")
}

@Test func aWriteKeepsTheFilesPermissions() throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.toml")
    try Data("old".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

    try LinkPreservingWrite.write(Data("new".utf8), to: file)

    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(try String(contentsOf: file, encoding: .utf8) == "new")
}

@Test func aWriteCreatesAFileThatIsNotThereYet() throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("settings.json")

    try LinkPreservingWrite.write(Data("{}".utf8), to: file)

    #expect(try String(contentsOf: file, encoding: .utf8) == "{}")
}
