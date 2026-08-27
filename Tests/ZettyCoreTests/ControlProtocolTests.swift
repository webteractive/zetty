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
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.scratch(focus: false))) == .scratch(focus: false))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.scratch(focus: true))) == .scratch(focus: true))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.scratchClear)) == .scratchClear)
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.newTab(project: "glen", focus: true, account: nil))) == .newTab(project: "glen", focus: true, account: nil))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.newTab(project: nil, focus: false, account: nil))) == .newTab(project: nil, focus: false, account: nil))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.addProject(path: "/Users/x/proj", name: "proj", space: nil, focus: true)))
            == .addProject(path: "/Users/x/proj", name: "proj", space: nil, focus: true))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.addProject(path: "/Users/x/proj", name: nil, space: nil, focus: false)))
            == .addProject(path: "/Users/x/proj", name: nil, space: nil, focus: false))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.removeProject(name: "zetty", fetch: false, discard: false)))
            == .removeProject(name: "zetty", fetch: false, discard: false))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.hibernateProject(name: "api"))) == .hibernateProject(name: "api"))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.wakeProject(name: "api"))) == .wakeProject(name: "api"))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(
        ControlRequest.newProject(path: "/Users/x/new", name: "new", gitInit: true, focus: true)))
        == .newProject(path: "/Users/x/new", name: "new", gitInit: true, focus: true))
    // gitInit defaults to false when the key is absent.
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(
        ControlRequest.newProject(path: "/Users/x/new", name: nil, gitInit: false, focus: false)))
        == .newProject(path: "/Users/x/new", name: nil, gitInit: false, focus: false))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.close(target: .pane("ab12"), wholeTab: true)))
            == .close(target: .pane("ab12"), wholeTab: true))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.quit(killSessions: false))) == .quit(killSessions: false))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.quit(killSessions: true))) == .quit(killSessions: true))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.split(target: .focused, vertical: true, focus: false, account: nil)))
            == .split(target: .focused, vertical: true, focus: false, account: nil))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.split(target: .pane("ab12"), vertical: false, focus: true, account: nil)))
            == .split(target: .pane("ab12"), vertical: false, focus: true, account: nil))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.breakPane(target: .pane("ab12"), focus: true)))
            == .breakPane(target: .pane("ab12"), focus: true))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.breakPane(target: .focused, focus: false)))
            == .breakPane(target: .focused, focus: false))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.focus(target: .pane("ab12"))))
            == .focus(target: .pane("ab12")))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.capture(target: .cwd("/x"), lines: 40)))
            == .capture(target: .cwd("/x"), lines: 40))
    #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(ControlRequest.capture(target: .focused, lines: nil)))
            == .capture(target: .focused, lines: nil))
}

@Test func focusDefaultsToFalseWhenAbsent() throws {
    // Simulate an older CLI that omits the focus key (backward compatibility).
    #expect(try ControlWire.decodeRequest(#"{"command":"new-tab"}"#) == .newTab(project: nil, focus: false, account: nil))
    #expect(try ControlWire.decodeRequest(#"{"command":"scratch"}"#) == .scratch(focus: false))
    #expect(try ControlWire.decodeRequest(#"{"command":"split","target":{"kind":"focused"}}"#) == .split(target: .focused, vertical: true, focus: false, account: nil))
    #expect(try ControlWire.decodeRequest(#"{"command":"break","target":{"kind":"focused"}}"#) == .breakPane(target: .focused, focus: false))
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
        .init(name: "zetty", isActive: true, hibernated: false, tabs: [
            .init(title: "claude", isActive: true, panes: [
                .init(id: "abcd1234", title: "✳ Claude Code", cwd: "/x", tool: "claude",
                      agentStatus: "running", isFocused: true, live: true),
            ]),
        ]),
        .init(name: "api", isActive: false, hibernated: true, tabs: [
            .init(title: "shell", isActive: false, panes: [
                .init(id: "beef0001", title: nil, cwd: "/y", tool: nil,
                      agentStatus: nil, isFocused: false, live: false),
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

/// A payload written before `hibernated`/`live` existed must still decode — a
/// stale standalone `zetty` build can talk to a newer app. Both default to the
/// safe "nothing claimed" value rather than throwing.
@Test func statusSnapshotDecodesPayloadWithoutHibernationFields() throws {
    let legacy = """
    {"ok":true,"status":{"projects":[{"name":"api","isActive":true,"tabs":[\
    {"title":"shell","isActive":true,"panes":[{"id":"abcd1234","isFocused":true}]}]}]}}
    """
    guard case .status(let snapshot) = try ControlWire.decodeResponse(legacy) else {
        Issue.record("expected status response")
        return
    }
    let project = try #require(snapshot.projects.first)
    #expect(project.hibernated == false)
    #expect(project.isActive == true)
    let pane = try #require(snapshot.panes.first)
    #expect(pane.live == false)
    #expect(pane.isFocused == true)
}

// MARK: - Status rendering

@Test func statusLinesMarkHibernatedProjectsAndDeadPanes() {
    let snapshot = StatusSnapshot(projects: [
        .init(name: "zetty", isActive: true, hibernated: false, tabs: [
            .init(title: "claude", isActive: true, panes: [
                .init(id: "abcd1234", title: "claude", cwd: "/x", tool: "claude",
                      agentStatus: "running", isFocused: true, live: true),
            ]),
        ]),
        .init(name: "Event Platform", isActive: false, hibernated: true, tabs: [
            .init(title: "shell", isActive: false, panes: [
                .init(id: "d37a61a3", title: nil, cwd: "/y", tool: nil,
                      agentStatus: nil, isFocused: false, live: false),
            ]),
        ]),
    ])
    let lines = ControlCLI.statusLines(snapshot)

    #expect(lines.first { $0.contains("zetty") } == "● zetty")
    #expect(lines.first { $0.contains("Event Platform") } == "☾ Event Platform  (hibernated)")

    // The live pane carries no dormancy marker; the hibernated one does.
    #expect(lines.first { $0.contains("abcd1234") }
            == "      abcd1234  [claude]  (running)  claude  — /x  *")
    #expect(lines.first { $0.contains("d37a61a3") } == "      d37a61a3  -  — /y")
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
    .init(id: "abcd1234", title: "claude", cwd: "/Users/x/proj", tool: "claude",
          agentStatus: nil, isFocused: false, live: true),
    .init(id: "abff9999", title: "codex", cwd: "/Users/x/other", tool: "codex",
          agentStatus: nil, isFocused: true, live: true),
    .init(id: "12345678", title: "vim", cwd: "/Users/x/proj", tool: nil,
          agentStatus: nil, isFocused: false, live: false),
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

// MARK: - Clone verb + remove-project flags

@Test func cloneProjectRequestRoundTrips() throws {
    let request = ControlRequest.cloneProject(project: "zetty", name: "fix-auth", focus: true)
    let line = try ControlWire.encodeLine(request)
    #expect(try ControlWire.decodeRequest(line) == request)

    let defaults = ControlRequest.cloneProject(project: nil, name: nil, focus: false)
    let defaultsLine = try ControlWire.encodeLine(defaults)
    #expect(try ControlWire.decodeRequest(defaultsLine) == defaults)
}

@Test func removeProjectFlagsRoundTripAndDefaultFalse() throws {
    let request = ControlRequest.removeProject(name: "zetty/fork-1", fetch: true, discard: false)
    let line = try ControlWire.encodeLine(request)
    #expect(try ControlWire.decodeRequest(line) == request)

    // A pre-flags CLI sends no fetch/discard keys — they must decode false.
    let legacy = #"{"command":"remove-project","project":"alpha"}"#
    #expect(try ControlWire.decodeRequest(legacy)
            == .removeProject(name: "alpha", fetch: false, discard: false))
}

@Test func cliRecognizesClone() {
    #expect(ControlCLI.recognizes(["clone"]))
    #expect(ControlCLI.recognizes(["clone", "--project", "zetty"]))
}

@Test func updateCloneRequestRoundTrips() throws {
    let line = try ControlWire.encodeLine(.updateClone(name: "zetty/fork-1"))
    let decoded = try ControlWire.decodeRequest(line)
    #expect(decoded == .updateClone(name: "zetty/fork-1"))
}
