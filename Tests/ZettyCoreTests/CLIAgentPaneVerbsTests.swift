import Foundation
import Testing
@testable import ZettyCore

/// `restart-agent` and `edit`: the CLI ends of the pane's ⟳ button and its
/// Open in Editor, which the Claude mod's `/z-reload` and `/z-open`
/// call for their own pane.

// MARK: - restart-agent

@Test func restartAgentCarriesItsTargetAndForce() {
    let cases: [([String], ControlRequest)] = [
        (["restart-agent", "--pane", "ab12"], .restartAgent(target: .pane("ab12"), force: false)),
        (["restart-agent", "--pane", "ab12", "--force"], .restartAgent(target: .pane("ab12"), force: true)),
        (["restart-agent", "--force", "--cwd", "/tmp/x"], .restartAgent(target: .cwd("/tmp/x"), force: true)),
    ]
    for (arguments, expected) in cases {
        let (_, recorder) = runIsolated(arguments)
        #expect(recorder.requests == [expected], "\(arguments)")
    }
}

/// Restarting whichever agent holds focus is not something to do by accident.
@Test func restartAgentRefusesToGuessItsTarget() {
    for arguments in [["restart-agent"], ["restart-agent", "--force"],
                      ["restart-agent", "--pane"], ["restart-agent", "--pane", "ab12", "--bogus"]] {
        let (exit, recorder) = runIsolated(arguments)
        #expect(recorder.requests.isEmpty, "\(arguments) sent \(recorder.requests)")
        #expect(exit != 0, "\(arguments)")
    }
}

// MARK: - handoff

@Test func handoffCarriesItsTargetAndFlags() {
    let cases: [([String], ControlRequest)] = [
        (["handoff", "--pane", "ab12"], .handoffAgent(target: .pane("ab12"))),
        (["handoff", "--pane", "ab12", "--to", "work"], .handoffAgent(target: .pane("ab12"), to: "work")),
        (["handoff", "--cwd", "/tmp/x", "--to", "codex", "--force"],
         .handoffAgent(target: .cwd("/tmp/x"), to: "codex", force: true)),
        (["handoff", "--self", "--pane", "ab12"], .handoffAgent(target: .pane("ab12"), asking: true)),
        (["handoff", "--pane", "ab12", "--cancel"], .handoffAgent(target: .pane("ab12"), cancel: true)),
    ]
    for (arguments, expected) in cases {
        let (_, recorder) = runIsolated(arguments)
        #expect(recorder.requests == [expected], "\(arguments)")
    }
}

/// Ending whichever agent holds focus is not something to do by accident.
@Test func handoffRefusesToGuessItsTarget() {
    for arguments in [["handoff"], ["handoff", "--to", "work"], ["handoff", "--pane"],
                      ["handoff", "--pane", "ab12", "--to"], ["handoff", "--pane", "ab12", "--bogus"]] {
        let (exit, recorder) = runIsolated(arguments)
        #expect(recorder.requests.isEmpty, "\(arguments) sent \(recorder.requests)")
        #expect(exit != 0, "\(arguments)")
    }
}

// MARK: - edit

@Test func editTargetsThePaneOrDefaultsToTheFocusedOne() {
    let cases: [([String], ControlRequest)] = [
        (["edit"], .openInEditor(target: .focused)),
        (["edit", "--pane", "ab12"], .openInEditor(target: .pane("ab12"))),
        (["edit", "--cwd", "/tmp/x"], .openInEditor(target: .cwd("/tmp/x"))),
    ]
    for (arguments, expected) in cases {
        let (_, recorder) = runIsolated(arguments)
        #expect(recorder.requests == [expected], "\(arguments)")
    }
}

@Test func editRejectsUnknownArgumentsWithoutSending() {
    for arguments in [["edit", "--bogus"], ["edit", "--pane"], ["edit", "somewhere"]] {
        let (exit, recorder) = runIsolated(arguments)
        #expect(recorder.requests.isEmpty, "\(arguments) sent \(recorder.requests)")
        #expect(exit != 0, "\(arguments)")
    }
}

// MARK: - The wire

@Test func agentPaneVerbsSurviveTheWire() throws {
    let requests: [ControlRequest] = [
        .restartAgent(target: .pane("ab12"), force: true),
        .restartAgent(target: .cwd("/tmp/x"), force: false),
        .openInEditor(target: .focused),
        .openInEditor(target: .pane("ab12")),
        .handoffAgent(target: .pane("ab12"), to: "work", asking: true, force: true, cancel: false),
        .handoffAgent(target: .cwd("/tmp/x")),
    ]
    for request in requests {
        #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(request)) == request)
    }
}

/// Silence means "not forced", as for every gated verb: a caller that never
/// sends the flag must get the refusal, not an interrupted turn.
@Test func restartAgentWithoutForceOnTheWireIsNotForced() throws {
    let line = #"{"command":"restart-agent","target":{"kind":"pane","value":"ab12"}}"#
    #expect(try ControlWire.decodeRequest(line) == .restartAgent(target: .pane("ab12"), force: false))
}

/// The cached foreground map freezes while Zetty is not frontmost, which is
/// when a script or another agent calls `handoff`: it read "No Claude or Codex
/// is running" for a pane with Claude in it. A cancel needs no reading.
@Test func handoffTakesAFreshReadingAndACancelDoesNot() {
    #expect(ControlRequest.handoffAgent(target: .pane("ab12")).takesForegroundReading)
    #expect(ControlRequest.handoffAgent(target: .pane("ab12"), asking: true).takesForegroundReading)
    #expect(!ControlRequest.handoffAgent(target: .pane("ab12"), cancel: true).takesForegroundReading)
    // The gated verbs still take theirs, and the rest still do not.
    #expect(ControlRequest.hibernateProject(name: "Foo").takesForegroundReading)
    #expect(!ControlRequest.restartAgent(target: .pane("ab12")).takesForegroundReading)
}
