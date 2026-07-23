import Testing
import Foundation
@testable import ZettyCore

@Test func fileCopyBackNameStatusArgs() {
    #expect(FileCopyBack.nameStatusArgs(sourceRoot: "/s", cloneRoot: "/c")
            == ["diff", "--no-index", "--no-renames", "--name-status", "-z", "/s", "/c"])
}

@Test func fileCopyBackParsesAddedAndModifiedDropsDeleted() {
    // status\0absPath\0 pairs; A uses clone path, M/D use source path.
    let raw = "A\u{0}/c/new.txt\u{0}M\u{0}/s/mod.txt\u{0}D\u{0}/s/gone.txt\u{0}"
    let changes = FileCopyBack.parseNameStatusZ(raw, sourceRoot: "/s", cloneRoot: "/c")
    #expect(changes == [
        FileCopyBack.FileChange(relPath: "new.txt", kind: .added),
        FileCopyBack.FileChange(relPath: "mod.txt", kind: .modified),
    ])   // D dropped
}

@Test func fileCopyBackSkipsGitInternalPaths() {
    let raw = "M\u{0}/s/.git/config\u{0}A\u{0}/c/keep.txt\u{0}"
    let changes = FileCopyBack.parseNameStatusZ(raw, sourceRoot: "/s", cloneRoot: "/c")
    #expect(changes == [FileCopyBack.FileChange(relPath: "keep.txt", kind: .added)])
}

@Test func fileCopyBackParsesNestedRelPaths() {
    let raw = "M\u{0}/s/a/b/c.txt\u{0}"
    #expect(FileCopyBack.parseNameStatusZ(raw, sourceRoot: "/s", cloneRoot: "/c")
            == [FileCopyBack.FileChange(relPath: "a/b/c.txt", kind: .modified)])
}

@Test func fileCopyBackKeepBothName() {
    #expect(FileCopyBack.keepBothName("notes.txt") == "notes 2.txt")
    #expect(FileCopyBack.keepBothName("a/b/notes.txt") == "a/b/notes 2.txt")
    #expect(FileCopyBack.keepBothName("Makefile") == "Makefile 2")          // no extension
    #expect(FileCopyBack.keepBothName("archive.tar.gz") == "archive.tar 2.gz") // last ext only
    #expect(FileCopyBack.keepBothName(".env") == ".env 2")                   // dotfile: no ext split
}
