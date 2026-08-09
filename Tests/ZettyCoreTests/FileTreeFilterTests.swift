import Foundation
import Testing
@testable import ZettyCore

private func dir(_ name: String) -> FileTreeEntry {
    FileTreeEntry(name: name, path: "/r/\(name)", isDirectory: true)
}

private func file(_ name: String) -> FileTreeEntry {
    FileTreeEntry(name: name, path: "/r/\(name)", isDirectory: false)
}

// MARK: - Defaults show everything

@Test func defaultSettingsShowEverythingIncludingDotfiles() {
    let entries = [file("README.md"), file(".env"), dir(".git"), dir("Sources")]
    let visible = FileTreeFilter.visible(entries, settings: FileTreeSettings())
    #expect(visible.map(\.name) == [".git", "Sources", ".env", "README.md"])
}

@Test func directoriesSortBeforeFilesThenCaseInsensitiveByName() {
    let entries = [file("zebra.txt"), dir("Beta"), file("Alpha.txt"), dir("alpha")]
    let visible = FileTreeFilter.visible(entries, settings: FileTreeSettings())
    #expect(visible.map(\.name) == ["alpha", "Beta", "Alpha.txt", "zebra.txt"])
}

// MARK: - Hidden files

@Test func hiddenEntriesDropWhenShowHiddenIsFalse() {
    let entries = [file("README.md"), file(".env"), dir(".git")]
    let settings = FileTreeSettings(showHidden: false)
    #expect(FileTreeFilter.visible(entries, settings: settings).map(\.name) == ["README.md"])
}

// MARK: - Extra ignores

@Test func extraIgnoresDropByNameCaseInsensitively() {
    let entries = [dir("node_modules"), dir("Sources"), dir("BUILD")]
    let settings = FileTreeSettings(extraIgnores: ["NODE_MODULES", "build"])
    #expect(FileTreeFilter.visible(entries, settings: settings).map(\.name) == ["Sources"])
}

@Test func blankExtraIgnoreEntriesAreHarmless() {
    let entries = [dir("Sources"), file("a.txt")]
    let settings = FileTreeSettings(extraIgnores: ["", "   "])
    #expect(FileTreeFilter.visible(entries, settings: settings).count == 2)
}

// MARK: - Gitignore gating

@Test func gitignorePredicateIsIgnoredWhenRespectGitignoreIsFalse() {
    let entries = [file("a.log"), file("b.txt")]
    let settings = FileTreeSettings(respectGitignore: false)
    let visible = FileTreeFilter.visible(entries, settings: settings) { $0.name.hasSuffix(".log") }
    #expect(visible.map(\.name) == ["a.log", "b.txt"])
}

@Test func gitignorePredicateAppliesWhenRespectGitignoreIsTrue() {
    let entries = [file("a.log"), file("b.txt")]
    let settings = FileTreeSettings(respectGitignore: true)
    let visible = FileTreeFilter.visible(entries, settings: settings) { $0.name.hasSuffix(".log") }
    #expect(visible.map(\.name) == ["b.txt"])
}

@Test func missingGitignorePredicateHidesNothing() {
    let entries = [file("a.log")]
    let settings = FileTreeSettings(respectGitignore: true)
    #expect(FileTreeFilter.visible(entries, settings: settings).count == 1)
}
