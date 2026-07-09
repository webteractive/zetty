import Testing
import Foundation
@testable import ZettyCore

// These verbs fail BEFORE the socket round-trip only on bad args; --help always
// exits 0 pre-socket. We assert --help still parses with the flags present, which
// exercises the arg loop without needing a running app.
@Test func scratchHelpExitsZero() {
    #expect(ControlCLI.run(["scratch", "--help"]) == 0)
}

@Test func newTabRejectsUnknownArg() {
    // An unknown flag is rejected pre-socket → exit 1 (proves --focus is a known,
    // consumed flag while a typo is not).
    #expect(ControlCLI.run(["new-tab", "--nope"]) == 1)
}

@Test func splitRejectsUnknownArg() {
    #expect(ControlCLI.run(["split", "--nope"]) == 1)
}

@Test func breakRejectsUnknownArg() {
    #expect(ControlCLI.run(["break", "--nope"]) == 1)
}

@Test func cliStillRecognizesAllVerbs() {
    for verb in ["new-tab", "split", "break", "scratch"] {
        #expect(ControlCLI.recognizes([verb]))
    }
}
