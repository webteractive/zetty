import Foundation
import Testing
@testable import ZettyCore

private let sample = """
  501     1   501 Ss   ??        0:12.34  8192 /bin/zsh -l
  502   501   502 S    s001      1:00.00 16384 node /usr/local/bin/claude
  503   502   502 S    s001      0:00.10  1024 rg --files
  900     1   900 Ss   ??        0:00.01   512 /usr/sbin/unrelated
"""

@Test func parsesEveryColumnAndKeepsTheCommandWhole() {
    let table = ProcessTable(psOutput: sample)
    let node = table.samples[502]
    #expect(node?.ppid == 501)
    #expect(node?.pgid == 502)
    #expect(node?.tty == "s001")
    #expect(node?.cpuSeconds == 60.0)
    // ps reports RSS in KiB. The expected value is precomputed: arithmetic
    // inside an #expect operand is typed as Int and compared against Int64?,
    // which fails while printing two identical numbers.
    let expectedRSS: Int64 = 16_384 * 1024
    #expect(node?.rssBytes == expectedRSS)
    // The command contains spaces and must survive intact — it is the last
    // field precisely so the split can stop before it.
    #expect(node?.command == "node /usr/local/bin/claude")
}

@Test func descendantsIncludeTheRootAndItsWholeSubtree() {
    let pids = Set(ProcessTable(psOutput: sample).descendants(of: 501).map(\.pid))
    #expect(pids == [501, 502, 503])
}

@Test func descendantsExcludeUnrelatedProcesses() {
    #expect(ProcessTable(psOutput: sample).descendants(of: 501).contains { $0.pid == 900 } == false)
}

@Test func anUnknownRootHasNoDescendants() {
    #expect(ProcessTable(psOutput: sample).descendants(of: 4242).isEmpty)
}

@Test func aParentCycleTerminatesInsteadOfHanging() {
    // pid reuse can produce a parent loop in a snapshot; walking it naively
    // never returns, and this runs on a timer.
    let cyclic = """
      10    11    10 S    s001      0:01.00  100 a
      11    10    10 S    s001      0:01.00  100 b
    """
    #expect(ProcessTable(psOutput: cyclic).descendants(of: 10).count == 2)
}

@Test func malformedLinesAreSkippedNotFatal() {
    let messy = "garbage\n\n  501     1   501 Ss   ??        0:12.34  8192 /bin/zsh\n"
    #expect(ProcessTable(psOutput: messy).samples.count == 1)
}
