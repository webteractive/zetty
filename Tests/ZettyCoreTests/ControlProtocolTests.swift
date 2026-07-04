import Testing
import Foundation
@testable import ZettyCore

// MARK: - Protocol round-trips

@Test func controlRequestRoundTripsThroughJSONLines() throws {
    let send = ControlRequest.send(target: PaneSelector.pane("abcd1234"), text: "ls", enter: true, keys: ["C-c"])
    let line = try ControlWire.encodeLine(send)
    // Exactly one newline: the line terminator (framing is one object per line).
    #expect(line.hasSuffix("\n") && !line.dropLast().contains("\n"))
    let decoded = try ControlWire.decodeRequest(line)
    #expect(decoded == send)

    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.status)) == .status)
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.reload)) == .reload)
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.newTab(project: "glen"))) == .newTab(project: "glen"))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.newTab(project: nil))) == .newTab(project: nil))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.addProject(path: "/Users/x/proj", name: "proj")))
            == .addProject(path: "/Users/x/proj", name: "proj"))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.addProject(path: "/Users/x/proj", name: nil)))
            == .addProject(path: "/Users/x/proj", name: nil))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.removeProject(name: "zetty"))) == .removeProject(name: "zetty"))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.close(target: .pane("ab12"), wholeTab: true)))
            == .close(target: .pane("ab12"), wholeTab: true))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.quit(killSessions: false))) == .quit(killSessions: false))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.quit(killSessions: true))) == .quit(killSessions: true))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.split(target: .focused, vertical: true)))
            == .split(target: .focused, vertical: true))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.breakPane(target: .pane("ab12"))))
            == .breakPane(target: .pane("ab12")))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.breakPane(target: .focused)))
            == .breakPane(target: .focused))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.focus(target: .pane("ab12"))))
            == .focus(target: .pane("ab12")))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.capture(target: .cwd("/x"), lines: 40)))
            == .capture(target: .cwd("/x"), lines: 40))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.capture(target: .focused, lines: nil)))
            == .capture(target: .focused, lines: nil))
}

@Test func controlResponseCarriesText() throws {
    let response = try ControlWire.decodeResponse(ControlWire.encodeLine(ControlResponse.text("line1\nline2")))
    #expect(response == .text("line1\nline2"))
}

@Test func controlResponseCarriesPaneID() throws {
    let response = try ControlWire.decodeResponse(ControlWire.encodeLine(ControlResponse.pane("abcd1234")))
    #expect(response == .pane("abcd1234"))
}

@Test func controlResponseCarriesStatusSnapshot() throws {
    let snapshot = StatusSnapshot(projects: [
        .init(name: "zetty", isActive: true, tabs: [
            .init(title: "claude", isActive: true, panes: [
                .init(id: "abcd1234", title: "✳ Claude Code", cwd: "/x", tool: "claude", agentStatus: "running", isFocused: true),
            ]),
        ]),
    ])
    let line = try ControlWire.encodeLine(ControlResponse.status(snapshot))
    let decoded = try ControlWire.decodeResponse(line)
    guard case .status(let back) = decoded else {
        Issue.record("expected status response")
        return
    }
    #expect(back == snapshot)

    let err = try ControlWire.decodeResponse(ControlWire.encodeLine(ControlResponse.error("no such pane")))
    guard case .error(let message) = err else {
        Issue.record("expected error response")
        return
    }
    #expect(message == "no such pane")
}

@Test func malformedRequestLineThrows() {
    #expect(throws: (any Error).self) { try ControlWire.decodeRequest("not json") }
}

// MARK: - Key notation

@Test func keyNotationEncodesCommonKeys() {
    #expect(KeyNotation.encode("Enter") == "\r")
    #expect(KeyNotation.encode("Tab") == "\t")
    #expect(KeyNotation.encode("Escape") == "\u{1b}")
    #expect(KeyNotation.encode("Space") == " ")
    #expect(KeyNotation.encode("Up") == "\u{1b}[A")
    #expect(KeyNotation.encode("Down") == "\u{1b}[B")
    #expect(KeyNotation.encode("Right") == "\u{1b}[C")
    #expect(KeyNotation.encode("Left") == "\u{1b}[D")
    #expect(KeyNotation.encode("BSpace") == "\u{7f}")
}

@Test func keyNotationEncodesControlChords() {
    #expect(KeyNotation.encode("C-c") == "\u{03}")
    #expect(KeyNotation.encode("C-d") == "\u{04}")
    #expect(KeyNotation.encode("C-l") == "\u{0c}")
    #expect(KeyNotation.encode("c-C") == "\u{03}")   // case-insensitive
}

@Test func keyNotationRejectsUnknownNames() {
    #expect(KeyNotation.encode("Bogus") == nil)
    #expect(KeyNotation.encode("C-1") == nil)
    #expect(KeyNotation.encode("") == nil)
}

// MARK: - Pane selection

private let panes: [StatusSnapshot.Pane] = [
    .init(id: "abcd1234", title: "claude", cwd: "/Users/x/proj", tool: "claude", agentStatus: nil, isFocused: false),
    .init(id: "abff9999", title: "codex", cwd: "/Users/x/other", tool: "codex", agentStatus: nil, isFocused: true),
    .init(id: "12345678", title: "vim", cwd: "/Users/x/proj", tool: nil, agentStatus: nil, isFocused: false),
]

@Test func selectorFocusedPicksTheFocusedPane() throws {
    #expect(try PaneSelector.focused.resolve(in: panes).id == "abff9999")
}

@Test func selectorPaneMatchesUniqueIDPrefix() throws {
    #expect(try PaneSelector.pane("1234").resolve(in: panes).id == "12345678")
    #expect(try PaneSelector.pane("abcd").resolve(in: panes).id == "abcd1234")
}

@Test func selectorPaneAmbiguousOrMissingThrows() {
    #expect(throws: (any Error).self) { try PaneSelector.pane("ab").resolve(in: panes) }      // ambiguous
    #expect(throws: (any Error).self) { try PaneSelector.pane("ffff").resolve(in: panes) }    // no match
}

@Test func selectorCwdMatchesNormalizedPath() throws {
    #expect(try PaneSelector.cwd("/Users/x/other/").resolve(in: panes).id == "abff9999")
    #expect(throws: (any Error).self) { try PaneSelector.cwd("/nope").resolve(in: panes) }
    // Two panes share /Users/x/proj → ambiguous.
    #expect(throws: (any Error).self) { try PaneSelector.cwd("/Users/x/proj").resolve(in: panes) }
}
