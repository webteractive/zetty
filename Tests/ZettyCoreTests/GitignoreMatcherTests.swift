import Foundation
import Testing
@testable import ZettyCore

private func matcher(_ contents: String, base: String = "/r") -> GitignoreMatcher {
    GitignoreMatcher(base: base, contents: contents)
}

// MARK: - Unanchored names match at any depth

@Test func bareNameMatchesAtAnyDepth() {
    let m = matcher("build")
    #expect(m.decision(path: "/r/build", isDirectory: true) == true)
    #expect(m.decision(path: "/r/a/b/build", isDirectory: true) == true)
    #expect(m.decision(path: "/r/src", isDirectory: true) == nil)
}

@Test func unanchoredExtensionMatchesAtAnyDepth() {
    let m = matcher("*.log")
    #expect(m.decision(path: "/r/a.log", isDirectory: false) == true)
    #expect(m.decision(path: "/r/deep/nest/a.log", isDirectory: false) == true)
    #expect(m.decision(path: "/r/a.txt", isDirectory: false) == nil)
}

// MARK: - Anchoring

@Test func leadingSlashAnchorsToTheGitignoreDirectory() {
    let m = matcher("/build")
    #expect(m.decision(path: "/r/build", isDirectory: true) == true)
    #expect(m.decision(path: "/r/a/build", isDirectory: true) == nil)
}

@Test func aSlashInsideThePatternAlsoAnchorsIt() {
    let m = matcher("docs/generated")
    #expect(m.decision(path: "/r/docs/generated", isDirectory: true) == true)
    #expect(m.decision(path: "/r/a/docs/generated", isDirectory: true) == nil)
}

// MARK: - Directory-only patterns

@Test func trailingSlashMatchesDirectoriesOnly() {
    let m = matcher("build/")
    #expect(m.decision(path: "/r/build", isDirectory: true) == true)
    #expect(m.decision(path: "/r/build", isDirectory: false) == nil)
}

// MARK: - Negation, last match wins

@Test func negationReinstatesAPreviouslyIgnoredFile() {
    let m = matcher("*.log\n!keep.log")
    #expect(m.decision(path: "/r/a.log", isDirectory: false) == true)
    #expect(m.decision(path: "/r/keep.log", isDirectory: false) == false)
}

@Test func lastMatchingPatternWinsEvenWhenItReIgnores() {
    let m = matcher("*.log\n!keep.log\nkeep.log")
    #expect(m.decision(path: "/r/keep.log", isDirectory: false) == true)
}

// MARK: - Double star

@Test func doubleStarSlashMatchesZeroOrMoreDirectories() {
    let m = matcher("docs/**/*.md")
    #expect(m.decision(path: "/r/docs/a.md", isDirectory: false) == true)
    #expect(m.decision(path: "/r/docs/x/y/a.md", isDirectory: false) == true)
    #expect(m.decision(path: "/r/other/a.md", isDirectory: false) == nil)
}

@Test func trailingDoubleStarMatchesEverythingBeneath() {
    let m = matcher("dist/**")
    #expect(m.decision(path: "/r/dist/a/b.js", isDirectory: false) == true)
}

// MARK: - Single star does not cross a separator

@Test func singleStarDoesNotCrossASeparator() {
    let m = matcher("/a/*.txt")
    #expect(m.decision(path: "/r/a/b.txt", isDirectory: false) == true)
    #expect(m.decision(path: "/r/a/deep/b.txt", isDirectory: false) == nil)
}

// MARK: - Character classes

@Test func characterClassMatches() {
    let m = matcher("file[0-9].txt")
    #expect(m.decision(path: "/r/file3.txt", isDirectory: false) == true)
    #expect(m.decision(path: "/r/fileX.txt", isDirectory: false) == nil)
}

@Test func negatedCharacterClassMatches() {
    let m = matcher("file[!0-9].txt")
    #expect(m.decision(path: "/r/fileX.txt", isDirectory: false) == true)
    #expect(m.decision(path: "/r/file3.txt", isDirectory: false) == nil)
}

// MARK: - Tolerance

@Test func commentsAndBlankLinesAreSkipped() {
    let m = matcher("# a comment\n\n   \nbuild")
    #expect(m.decision(path: "/r/build", isDirectory: true) == true)
    #expect(m.decision(path: "/r/a comment", isDirectory: false) == nil)
}

@Test func escapedHashIsALiteralName() {
    let m = matcher("\\#notes")
    #expect(m.decision(path: "/r/#notes", isDirectory: false) == true)
}

@Test func unclosedCharacterClassDoesNotCrash() {
    let m = matcher("file[0-9.txt")
    #expect(m.decision(path: "/r/anything", isDirectory: false) == nil)
}

@Test func trailingWhitespaceIsNotSignificant() {
    let m = matcher("build   ")
    #expect(m.decision(path: "/r/build", isDirectory: true) == true)
}

@Test func crlfLineEndingsParse() {
    let m = matcher("build\r\n*.log\r")
    #expect(m.decision(path: "/r/build", isDirectory: true) == true)
    #expect(m.decision(path: "/r/a.log", isDirectory: false) == true)
}

// MARK: - Paths outside the base

@Test func pathsOutsideTheBaseGetNoOpinion() {
    let m = matcher("build", base: "/r")
    #expect(m.decision(path: "/elsewhere/build", isDirectory: true) == nil)
}

// MARK: - Stack layering

@Test func deeperGitignoreOverridesAShallowerOne() {
    let stack = GitignoreStack(matchers: [
        matcher("*.log", base: "/r"),
        matcher("!important.log", base: "/r/logs"),
    ])
    #expect(stack.isIgnored(path: "/r/a.log", isDirectory: false) == true)
    #expect(stack.isIgnored(path: "/r/logs/important.log", isDirectory: false) == false)
}

@Test func stackOrdersByDepthNotByInputOrder() {
    let stack = GitignoreStack(matchers: [
        matcher("!important.log", base: "/r/logs"),
        matcher("*.log", base: "/r"),
    ])
    #expect(stack.isIgnored(path: "/r/logs/important.log", isDirectory: false) == false)
}

@Test func emptyStackIgnoresNothing() {
    #expect(GitignoreStack(matchers: []).isIgnored(path: "/r/a.log", isDirectory: false) == false)
}
