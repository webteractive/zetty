import Foundation
import Testing
@testable import ZettyCore

@Test func parsesMinutesAndSeconds() {
    #expect(CPUTime.seconds(from: "0:00.53") == 0.53)
    #expect(CPUTime.seconds(from: "12:34.56") == 754.56)
}

@Test func parsesHours() {
    #expect(CPUTime.seconds(from: "1:02:03") == 3723)
}

@Test func parsesDays() {
    // The shape that breaks a naive split on ":" — and the processes that
    // reach it are the long-running ones this tool is for.
    #expect(CPUTime.seconds(from: "2-03:04:05") == 183845)
}

@Test func toleratesSurroundingWhitespace() {
    #expect(CPUTime.seconds(from: "  0:01.00 ") == 1.0)
}

@Test func rejectsGarbageRatherThanGuessing() {
    #expect(CPUTime.seconds(from: "") == nil)
    #expect(CPUTime.seconds(from: "abc") == nil)
    #expect(CPUTime.seconds(from: "1:2:3:4") == nil)
    #expect(CPUTime.seconds(from: "-5:00") == nil)
}
