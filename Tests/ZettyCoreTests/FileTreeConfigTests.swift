import Foundation
import Testing
@testable import ZettyCore

// MARK: - Defaults

@Test func fileTreeDefaultsShowEverythingAtTheDefaultWidth() {
    let config = AppConfig.parse("")
    #expect(config.fileTree.showHidden == true)
    #expect(config.fileTree.respectGitignore == false)
    #expect(config.fileTree.extraIgnores.isEmpty)
    #expect(config.fileTree.width == FileTreeSettings.defaultWidth)
}

// MARK: - Parsing

@Test func fileTreeKeysParse() {
    let config = AppConfig.parse("""
    zetty-file-tree-show-hidden = false
    zetty-file-tree-respect-gitignore = true
    zetty-file-tree-ignore = node_modules, .git , vendor
    zetty-file-tree-width = 320
    """)
    #expect(config.fileTree.showHidden == false)
    #expect(config.fileTree.respectGitignore == true)
    #expect(config.fileTree.extraIgnores == ["node_modules", ".git", "vendor"])
    #expect(config.fileTree.width == 320)
}

@Test func fileTreeWidthIgnoresNonsense() {
    #expect(AppConfig.parse("zetty-file-tree-width = wide").fileTree.width == FileTreeSettings.defaultWidth)
    #expect(AppConfig.parse("zetty-file-tree-width = -5").fileTree.width == FileTreeSettings.defaultWidth)
    #expect(AppConfig.parse("zetty-file-tree-width = 0").fileTree.width == FileTreeSettings.defaultWidth)
}

@Test func fileTreeBooleansAcceptTheUsualTruthyWords() {
    for value in ["true", "yes", "on", "1"] {
        #expect(AppConfig.parse("zetty-file-tree-respect-gitignore = \(value)").fileTree.respectGitignore == true)
    }
    #expect(AppConfig.parse("zetty-file-tree-respect-gitignore = nope").fileTree.respectGitignore == false)
}

// MARK: - The reserved-key trap

/// None of the four keys may ever reach ghostty: one key ghostty rejects frees
/// the WHOLE config, including the per-surface `command` behind preserved
/// sessions.
@Test func fileTreeKeysAreNeverForwardedToGhostty() {
    let config = AppConfig.parse("""
    zetty-file-tree-show-hidden = false
    zetty-file-tree-respect-gitignore = true
    zetty-file-tree-ignore = node_modules
    zetty-file-tree-width = 320
    """)
    #expect(config.ghostty.isEmpty)
    #expect(config.unsupportedKeys.isEmpty)
}

/// `zetty-` is the namespace for Zetty's own keys, so a key from a newer build
/// is swallowed rather than poisoning the passthrough.
@Test func unknownFileTreeKeyIsSwallowedNotForwarded() {
    let config = AppConfig.parse("zetty-file-tree-future-thing = true")
    #expect(config.ghostty.isEmpty)
    #expect(config.unsupportedKeys == ["zetty-file-tree-future-thing"])
}

/// The protection is the whole `zetty-` namespace, not a list of known keys —
/// that's the point of the prefix. Any future key is safe the moment it's named.
@Test func anyUnknownZettyPrefixedKeyIsSwallowed() {
    let config = AppConfig.parse("zetty-something-nobody-has-written-yet = 42")
    #expect(config.ghostty.isEmpty)
    #expect(config.unsupportedKeys == ["zetty-something-nobody-has-written-yet"])
}

/// A bare `file-tree-*` key (the pre-prefix spelling that never shipped) is NOT
/// reserved, so it forwards to ghostty like any other unknown directive. This
/// pins the decision: `zetty-` is the namespace, `file-tree-` is not.
@Test func bareFileTreeKeyIsNotReserved() {
    let config = AppConfig.parse("file-tree-show-hidden = false")
    #expect(config.unsupportedKeys.isEmpty)
    #expect(config.ghostty.count == 1)
}

// MARK: - Rendering

@Test func fileTreeKeysSurviveARenderRoundTrip() {
    let original = AppConfig.parse("""
    zetty-file-tree-show-hidden = false
    zetty-file-tree-respect-gitignore = true
    zetty-file-tree-ignore = node_modules, vendor
    zetty-file-tree-width = 320
    """)
    let reparsed = AppConfig.parse(original.rendered())
    #expect(reparsed.fileTree == original.fileTree)
}

@Test func renderedDefaultsAlsoRoundTrip() {
    let original = AppConfig.parse("")
    let reparsed = AppConfig.parse(original.rendered())
    #expect(reparsed.fileTree == original.fileTree)
}
