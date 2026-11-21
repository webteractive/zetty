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

/// `~/.claude` linked to a dotfiles folder, and its settings.json a relative
/// link (`../shared/settings.json`): the kernel resolves `..` from the
/// folder's real location, so the write must too, or it lands in an
/// unrelated file beside the link (security review of 70c34a5..cb4df1b).
@Test func aRelativeLinkResolvesFromItsFoldersRealLocation() throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    let dotClaude = dir.appendingPathComponent("dot/claude")
    let dotShared = dir.appendingPathComponent("dot/shared")
    let homeShared = dir.appendingPathComponent("home/shared")
    for folder in [dotClaude, dotShared, homeShared] {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let linkedFolder = dir.appendingPathComponent("home/.claude")
    try fm.createSymbolicLink(at: linkedFolder, withDestinationURL: dotClaude)
    try Data("old".utf8).write(to: dotShared.appendingPathComponent("settings.json"))
    try Data("unrelated".utf8).write(to: homeShared.appendingPathComponent("settings.json"))
    try fm.createSymbolicLink(atPath: dotClaude.appendingPathComponent("settings.json").path,
                              withDestinationPath: "../shared/settings.json")

    try LinkPreservingWrite.write(Data("new".utf8), to: linkedFolder.appendingPathComponent("settings.json"))

    #expect(try String(contentsOf: dotShared.appendingPathComponent("settings.json"), encoding: .utf8) == "new")
    #expect(try String(contentsOf: homeShared.appendingPathComponent("settings.json"), encoding: .utf8) == "unrelated")
}

/// A loop of links has no file to write: replacing one of its links with a
/// regular file would quietly break the user's layout.
@Test func aLinkLoopFailsInsteadOfReplacingALink() throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    let a = dir.appendingPathComponent("a.json")
    let b = dir.appendingPathComponent("b.json")
    try fm.createSymbolicLink(atPath: a.path, withDestinationPath: "b.json")
    try fm.createSymbolicLink(atPath: b.path, withDestinationPath: "a.json")

    #expect(throws: (any Error).self) { try LinkPreservingWrite.write(Data("new".utf8), to: a) }
    #expect((try? fm.destinationOfSymbolicLink(atPath: a.path)) == "b.json")
    #expect((try? fm.destinationOfSymbolicLink(atPath: b.path)) == "a.json")
}

/// Seeding an account copies `settings.json`; a copy of a link is a link, so
/// the account's hook writes went through it into the shared file instead of
/// the account's own (security review of 70c34a5..cb4df1b).
@Test func aCopyOfALinkedFileIsARealFileWithItsContents() throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    let real = dir.appendingPathComponent("dotfiles-settings.json")
    let link = dir.appendingPathComponent("settings.json")
    let copy = dir.appendingPathComponent("account-settings.json")
    try Data("shared".utf8).write(to: real)
    try fm.createSymbolicLink(at: link, withDestinationURL: real)

    try LinkPreservingWrite.copyTarget(of: link, to: copy)

    #expect((try? fm.destinationOfSymbolicLink(atPath: copy.path)) == nil)
    #expect(try String(contentsOf: copy, encoding: .utf8) == "shared")
}
