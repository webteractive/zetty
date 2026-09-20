import Foundation
import Testing
@testable import ZettyCore

private func table(_ text: String) -> ProcessTable { ProcessTable(psOutput: text) }

private let before = table("""
  501     1   501 Ss   ??        0:10.00  8192 /bin/zsh -l
  502   501   502 S    s001      0:20.00 16384 node claude
""")

private let after = table("""
  501     1   501 Ss   ??        0:10.00  8192 /bin/zsh -l
  502   501   502 S    s001      0:23.00 16384 node claude
""")

/// Precomputed: arithmetic inside an #expect operand is typed as Int and
/// compared against Int64, which fails while printing identical numbers.
private let pairRSS: Int64 = (8_192 + 16_384) * 1024
private let soloRSS: Int64 = 4_096 * 1024

@Test func loadSumsTheShellAndItsChildren() {
    // The shell is rarely the expensive process; the agent under it is.
    let load = SessionLoad.measure(rootPID: 501, table: after, previous: before, elapsed: 3)
    #expect(load.processCount == 2)
    #expect(load.rssBytes == pairRSS)
    #expect(load.cpuPercent == 100)
}

@Test func theFirstMeasurementReportsMemoryButNoRate() {
    let load = SessionLoad.measure(rootPID: 501, table: after, previous: nil, elapsed: 3)
    #expect(load.cpuPercent == nil)
    #expect(load.rssBytes == pairRSS)
}

@Test func aLoneShellIsMeasurable() {
    let solo = table("  700     1   700 Ss   ??        0:01.00  4096 /bin/zsh")
    let load = SessionLoad.measure(rootPID: 700, table: solo, previous: nil, elapsed: 3)
    #expect(load.processCount == 1)
    #expect(load.rssBytes == soloRSS)
}

@Test func aDeadSessionMeasuresAsNothing() {
    // The session vanished between `zmx list` and the ps sweep.
    let load = SessionLoad.measure(rootPID: 9999, table: after, previous: before, elapsed: 3)
    #expect(load.processCount == 0)
    #expect(load.rssBytes == 0)
    #expect(load.cpuPercent == nil)
}
