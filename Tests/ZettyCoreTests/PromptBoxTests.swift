import Foundation
import Testing
@testable import ZettyCore

/// `hibernate-after` may only put away an agent pane whose prompt box is
/// empty: a draft means somebody is in the middle of something. The fixtures
/// under `Fixtures/promptbox` are real screens (`zmx history --vt`) from
/// claude 2.1.292 and codex 0.160.1, cut to the rows around the box.

private let rule = String(repeating: "─", count: 40)

@Test func anEmptyClaudeBoxIsEmpty() {
    #expect(PromptBox.isEmpty(screen: "output\n\(rule)\n❯ \n\(rule)\n  ? for shortcuts"))
}

@Test func aDraftIsNotEmpty() {
    #expect(!PromptBox.isEmpty(screen: "\(rule)\n❯ fix the tests\n\(rule)"))
}

@Test func aQuestionMenuIsNotEmpty() {
    // A permission prompt replaces the box with a menu whose selected row
    // starts with the same glyph.
    #expect(!PromptBox.isEmpty(screen: "Do you want to proceed?\n❯ 1. Yes\n  2. No"))
}

@Test func aScreenWithNoBoxIsNotEmpty() {
    #expect(!PromptBox.isEmpty(screen: "$ ls\nREADME.md"))
    #expect(!PromptBox.isEmpty(screen: ""))
}

@Test func theLastBoxOnTheScreenDecides() {
    let earlier = "\(rule)\n❯ \n\(rule)"
    #expect(!PromptBox.isEmpty(screen: "\(earlier)\nreply\n\(rule)\n❯ draft\n\(rule)"))
}

@Test func aFaintSuggestionIsStillEmptyButFaintAnythingElseIsADraft() {
    let faint = "\u{1B}[2m", reset = "\u{1B}[0m"
    #expect(PromptBox.isEmpty(vtScreen: "\(rule)\n❯ \(faint)Try \"fix lint errors\"\(reset)\n\(rule)"))
    #expect(!PromptBox.isEmpty(vtScreen: "\(rule)\n❯ \(faint)[Pasted text #1]\(reset)\n\(rule)"))
}

@Test func aColourIsNotMistakenForFaint() {
    // 38;2;136;136;136 holds a `2` that is part of a colour, not SGR 2.
    let grey = "\u{1B}[38;2;136;136;136m", reset = "\u{1B}[0m"
    #expect(!PromptBox.isEmpty(vtScreen: "\(rule)\n❯ \(grey)typed\(reset)\n\(rule)"))
}

@Test func theCapturedClaudeFixturesReadAsExpected() throws {
    #expect(PromptBox.isEmpty(vtScreen: try fixture("claude-empty"), agent: .claude))
    for name in ["claude-draft", "claude-question"] {
        #expect(!PromptBox.isEmpty(vtScreen: try fixture(name), agent: .claude), "\(name)")
    }
    // Claude's box is the same empty `❯` while it works, so the box cannot
    // keep a working Claude awake: its hook status does.
    #expect(PromptBox.isEmpty(vtScreen: try fixture("claude-working"), agent: .claude))
}

@Test func theCapturedCodexFixturesReadAsExpected() throws {
    #expect(PromptBox.isEmpty(vtScreen: try fixture("codex-empty"), agent: .codex))
    // Working must read as NOT empty here: Codex's one hook cannot tell
    // working from idle, so this reader is the only thing that can.
    for name in ["codex-draft", "codex-question", "codex-working"] {
        #expect(!PromptBox.isEmpty(vtScreen: try fixture(name), agent: .codex), "\(name)")
    }
}

@Test func aHarnessWithNoReaderIsNeverEmpty() {
    #expect(!PromptBox.isEmpty(vtScreen: "\(rule)\n❯ \n\(rule)", agent: .aider))
}

@Test func oneHarnessesBoxIsNotReadAsAnothers() {
    #expect(!PromptBox.isEmpty(vtScreen: "\(rule)\n❯ \n\(rule)", agent: .codex))
    #expect(!PromptBox.isEmpty(vtScreen: "› ", agent: .claude))
}

@Test func onlyTheTailOfALongHistoryIsRead() {
    let short = String(repeating: "─", count: 8)
    let box = "\(short)\n❯ \n\(short)\n"                      // 55 bytes
    let history = Data((String(repeating: "x", count: 500) + "\nscrollback\n" + box).utf8)
    // The cut lands inside "scrollback" and moves forward to a line start,
    // never leaving half a line (or half a character) at the top.
    let tail = PromptBox.tail(of: history, limit: 60)
    #expect(tail == box)
    #expect(PromptBox.isEmpty(screen: tail))
    #expect(PromptBox.tail(of: Data(box.utf8), limit: 60) == box)
}

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "vt",
                                             subdirectory: "Fixtures/promptbox"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}
