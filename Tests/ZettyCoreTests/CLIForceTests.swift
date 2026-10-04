import Foundation
import Testing
@testable import ZettyCore

/// A destructive verb arriving over the socket must never wait on a dialog:
/// `scratch-clear` with a busy scratch once raised `NSAlert.runModal` on the
/// main thread and froze every zetty command until someone clicked. Busy panes
/// are refused with an error instead, and `--force` proceeds.

// MARK: - The gate

@Test func busyPanesAreRefusedWithTheirIdsAndTheWayOut() {
    let message = BusyPaneGate.refusal(
        busy: [.init(pane: "1e3aebe3", command: "claude"), .init(pane: "ab12cd34", command: "node")],
        force: false)
    #expect(message == "2 busy panes: 1e3aebe3 (claude), ab12cd34 (node) — pass --force to close them anyway")
}

@Test func oneBusyPaneReadsInTheSingular() {
    let message = BusyPaneGate.refusal(busy: [.init(pane: "1e3aebe3", command: "claude")], force: false)
    #expect(message == "1 busy pane: 1e3aebe3 (claude) — pass --force to close it anyway")
}

@Test func forceOrNothingBusyProceeds() {
    #expect(BusyPaneGate.refusal(busy: [.init(pane: "1e3aebe3", command: "claude")], force: true) == nil)
    #expect(BusyPaneGate.refusal(busy: [], force: false) == nil)
}

// MARK: - The CLI carries the flag

@Test func forceReachesTheRequestForEveryGatedVerb() {
    let cases: [([String], ControlRequest)] = [
        (["scratch-clear", "--force"], .scratchClear(force: true)),
        (["close", "--pane", "ab12", "--force"], .close(target: .pane("ab12"), wholeTab: false, force: true)),
        (["remove-project", "Foo", "--force"], .removeProject(name: "Foo", fetch: false, discard: false, force: true)),
        (["hibernate", "Foo", "--force"], .hibernateProject(name: "Foo", force: true)),
        (["hibernate", "--space", "Work", "--force"], .hibernateSpace(name: "Work", force: true)),
        (["quit", "--kill-sessions", "--force"], .quit(killSessions: true, simulateRestart: false, force: true)),
    ]
    for (arguments, expected) in cases {
        let (_, recorder) = runIsolated(arguments)
        #expect(recorder.requests == [expected], "\(arguments)")
    }
}

@Test func withoutForceTheRequestAsksToBeRefusedWhenBusy() {
    let cases: [([String], ControlRequest)] = [
        (["scratch-clear"], .scratchClear(force: false)),
        (["close", "--pane", "ab12", "--tab"], .close(target: .pane("ab12"), wholeTab: true, force: false)),
        (["remove-project", "Foo"], .removeProject(name: "Foo", fetch: false, discard: false, force: false)),
        (["hibernate", "Foo"], .hibernateProject(name: "Foo", force: false)),
        (["quit"], .quit(killSessions: false, simulateRestart: false, force: false)),
    ]
    for (arguments, expected) in cases {
        let (_, recorder) = runIsolated(arguments)
        #expect(recorder.requests == [expected], "\(arguments)")
    }
}

@Test func verbsThatTookNoArgumentsNowRejectUnknownOnes() {
    // `scratch-clear --bogus` used to clear everything; a typo must not act.
    for arguments in [["scratch-clear", "--bogus"], ["quit", "--kil-sessions"], ["wake", "Foo", "--force"]] {
        let (exit, recorder) = runIsolated(arguments)
        #expect(recorder.requests.isEmpty, "\(arguments) sent \(recorder.requests)")
        #expect(exit != 0)
    }
}

// MARK: - The wire

@Test func forceSurvivesTheWireAndOldClientsMeanNotForced() throws {
    for request: ControlRequest in [.scratchClear(force: true),
                                    .close(target: .pane("ab12"), wholeTab: true, force: true),
                                    .removeProject(name: "a", fetch: false, discard: false, force: true),
                                    .hibernateProject(name: "a", force: true),
                                    .hibernateSpace(name: "S", force: true),
                                    .quit(killSessions: true, simulateRestart: false, force: true)] {
        #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(request)) == request)
    }
    #expect(try ControlWire.decodeRequest(#"{"command":"scratch-clear"}"#) == .scratchClear(force: false))
    #expect(try ControlWire.decodeRequest(#"{"command":"hibernate","project":"a"}"#)
        == .hibernateProject(name: "a", force: false))
}
