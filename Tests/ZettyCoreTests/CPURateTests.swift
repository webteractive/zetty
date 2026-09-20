import Foundation
import Testing
@testable import ZettyCore

@Test func theFirstSampleHasNoRateToReport() {
    // Nothing to difference against. nil renders as "—"; 0.0 would be a claim,
    // and a false one.
    #expect(CPURate.percent(now: [1: 10], previous: nil, elapsed: 3) == nil)
}

@Test func oneSecondOfCpuOverTwoSecondsIsFiftyPercent() {
    #expect(CPURate.percent(now: [1: 11], previous: [1: 10], elapsed: 2) == 50)
}

@Test func coresAboveOneHundredPercentAreNotClamped() {
    // A parallel build genuinely uses more than one core; clamping would hide
    // exactly the process this tool exists to find.
    #expect(CPURate.percent(now: [1: 6, 2: 6], previous: [1: 0, 2: 0], elapsed: 3) == 400)
}

@Test func aProcessThatVanishedContributesNothing() {
    #expect(CPURate.percent(now: [1: 11], previous: [1: 10, 2: 500], elapsed: 2) == 50)
}

@Test func aProcessThatAppearedContributesNothingThisTick() {
    // Counting a newcomer's lifetime CPU as if it burned in one interval
    // spikes the row to nonsense. It counts from the next tick.
    #expect(CPURate.percent(now: [1: 11, 2: 9_000], previous: [1: 10], elapsed: 2) == 50)
}

@Test func pidReuseCannotProduceANegativeRate() {
    // A recycled pid can report less cpu than its predecessor.
    #expect(CPURate.percent(now: [1: 1], previous: [1: 900], elapsed: 2) == 0)
}

@Test func aNonAdvancingClockYieldsNoRate() {
    #expect(CPURate.percent(now: [1: 11], previous: [1: 10], elapsed: 0) == nil)
    #expect(CPURate.percent(now: [1: 11], previous: [1: 10], elapsed: -4) == nil)
}
