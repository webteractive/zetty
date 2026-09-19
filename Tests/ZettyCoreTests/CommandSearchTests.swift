import Foundation
import Testing
@testable import ZettyCore

private let labels = [
    "New Tab",
    "Close Tab",
    "Toggle Sidebar",
    "Go to Project: zetty",
    "Go to Project: dotfiles",
    "Go to Tab: build",
    "Settings: Accounts",
    "Broadcast: Workspace",
]

private func ranked(_ query: String) -> [String] {
    CommandSearch.rank(query: query, labels: labels).map { labels[$0] }
}

@Test func anEmptyQueryKeepsEverythingInOrder() {
    // The palette shows the full list before anything is typed, and the
    // author's ordering is meaningful — don't re-sort it by score.
    #expect(CommandSearch.rank(query: "", labels: labels) == Array(labels.indices))
    #expect(CommandSearch.rank(query: "   ", labels: labels) == Array(labels.indices))
}

@Test func matchesASubsequenceRatherThanASubstring() {
    // "go zetty" is not a substring of "Go to Project: zetty"; the old
    // `contains` filter found nothing for it, which is the whole point.
    #expect(ranked("go zetty").first == "Go to Project: zetty")
}

@Test func termsMayBeGivenInAnyOrder() {
    // Typing the project first is at least as natural as typing the verb.
    #expect(ranked("zetty go").first == "Go to Project: zetty")
}

@Test func everyTermMustMatch() {
    // Space-separated terms are AND, not OR — otherwise a second word widens
    // the result set instead of narrowing it, which reads as broken.
    #expect(ranked("go dotfiles").contains("Go to Project: zetty") == false)
    #expect(ranked("go dotfiles") == ["Go to Project: dotfiles"])
}

@Test func initialsFindALabel() {
    #expect(ranked("tsb").first == "Toggle Sidebar")
}

@Test func aNonMatchYieldsNothing() {
    #expect(ranked("qqqq").isEmpty)
}

@Test func exactWordsOutrankScatteredLetters() {
    // "tab" appears whole in "New Tab" and "Close Tab", and scattered through
    // others; the whole-word hits must come first.
    let top = Set(ranked("tab").prefix(3))
    #expect(top.contains("New Tab"))
    #expect(top.contains("Close Tab"))
}

@Test func rankingIsStableForEqualScores() {
    // Two candidates scoring the same must not swap between keystrokes — the
    // selection is index 0, so an unstable order moves what Enter runs.
    let first = CommandSearch.rank(query: "go to", labels: labels)
    let second = CommandSearch.rank(query: "go to", labels: labels)
    #expect(first == second)
}

@Test func caseIsIgnored() {
    #expect(ranked("ZETTY").first == "Go to Project: zetty")
    #expect(ranked("GO ZeTtY").first == "Go to Project: zetty")
}
