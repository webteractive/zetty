import Foundation
import Testing
@testable import ZettyCore

@Test func theRequestAsksForAReplyAndNothingElse() {
    let text = HandoffPrompt.request
    for phrase in ["remembers nothing", "full path", "secrets", "Change no files", "Reply with the handoff only"] {
        #expect(text.contains(phrase), "\(phrase)")
    }
    // It becomes one argv entry; a leading dash would read as a flag.
    #expect(!text.hasPrefix("-"))
}

@Test func theWakeFileCarriesTheWakeLineThenTheHandoff() {
    let file = HandoffPrompt.wakeFile(handoff: "\n## Goal\nShip it.\n\n")
    #expect(file.hasPrefix("This project was hibernated"))
    #expect(file.hasSuffix("## Goal\nShip it."))
}

@Test func onlyACleanNonEmptyReplyUnderTheCapIsAHandoff() {
    #expect(HandoffOutput.accepted(exitCode: 0, stdout: Data("## Goal\n".utf8)) == "## Goal")
    #expect(HandoffOutput.accepted(exitCode: 1, stdout: Data("## Goal".utf8)) == nil)
    #expect(HandoffOutput.accepted(exitCode: 0, stdout: Data(" \n".utf8)) == nil)
    #expect(HandoffOutput.accepted(exitCode: 0, stdout: Data(count: HandoffOutput.maxBytes + 1)) == nil)
    #expect(HandoffOutput.accepted(exitCode: 0, stdout: Data([0xFF, 0xFE])) == nil)
}
