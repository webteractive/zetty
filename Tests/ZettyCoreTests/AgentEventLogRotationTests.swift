import Foundation
import Testing
@testable import ZettyCore

/// A log of `count` identical lines, each `"<index>\n"`-shaped and padded so the
/// size is predictable.
private func log(lines count: Int, lineLength: Int = 64) -> Data {
    var text = ""
    for i in 0..<count {
        let body = String(repeating: "x", count: max(0, lineLength - 1))
        text += "\(i)\(body.dropFirst(String(i).count))\n"
    }
    return Data(text.utf8)
}

@Test func rotationLeavesASmallLogAlone() {
    let data = log(lines: 10)
    #expect(AgentEventLogRotation.trimmed(data, maxBytes: 1024, keepBytes: 256) == nil)
}

@Test func rotationTrimsAnOversizedLogToRoughlyTheKeepWindow() throws {
    let data = log(lines: 1000)          // ~64 KB
    let trimmed = AgentEventLogRotation.trimmed(data, maxBytes: 8 * 1024, keepBytes: 4 * 1024)
    let result = try #require(trimmed)
    #expect(result.count <= 4 * 1024)
    #expect(result.count > 0)
    // The tail is preserved verbatim — rotation drops the head, never rewrites.
    #expect(data.suffix(result.count) == result)
}

@Test func rotationNeverLeavesAPartialLineAtTheHead() throws {
    // Cut deliberately mid-line: keepBytes lands inside a line body.
    let data = log(lines: 500, lineLength: 33)
    let result = try #require(
        AgentEventLogRotation.trimmed(data, maxBytes: 1024, keepBytes: 500)
    )
    let text = String(decoding: result, as: UTF8.self)
    // Every retained line is whole, so each starts with its index digits.
    for line in text.split(separator: "\n") {
        #expect(line.first?.isNumber == true)
    }
}

@Test func rotationRefusesWhenTheWindowHoldsNoLineBreak() {
    // One absurdly long line: there is no safe cut point, so leave it be
    // rather than corrupt it.
    let data = Data(String(repeating: "x", count: 4096).utf8)
    #expect(AgentEventLogRotation.trimmed(data, maxBytes: 100, keepBytes: 50) == nil)
}

@Test func rotationKeepWindowCoversTheReplayWindow() {
    // AgentEventReplay reads a 256 KB tail; rotating to less than that would
    // discard status the startup replay still needs.
    #expect(AgentEventLogRotation.defaultKeepBytes >= 256 * 1024)
    #expect(AgentEventLogRotation.defaultMaxBytes > AgentEventLogRotation.defaultKeepBytes)
}

@Test func rotatedLogStillReplaysTheLatestStatePerPane() throws {
    // End-to-end: an oversized log whose tail holds the current state must
    // survive rotation with that state intact.
    var text = ""
    for i in 0..<2000 {
        text += #"{"cwd": "/old/\#(i)", "agent": "claude", "event": "running"}"# + "\n"
    }
    text += #"{"cwd": "/live", "agent": "claude", "event": "needsAttention"}"# + "\n"
    let data = Data(text.utf8)

    let trimmed = try #require(
        AgentEventLogRotation.trimmed(data, maxBytes: 16 * 1024, keepBytes: 4 * 1024)
    )
    let events = AgentEventReplay.liveEvents(
        fromJSONL: String(decoding: trimmed, as: UTF8.self)
    )
    #expect(events.contains(AgentEvent(cwd: "/live", agent: .claude, event: .needsAttention)))
}
