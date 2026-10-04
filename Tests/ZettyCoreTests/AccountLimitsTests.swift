import Foundation
import Testing
@testable import ZettyCore

private let t0 = Date(timeIntervalSince1970: 1_791_000_000)
private let utc = TimeZone(identifier: "UTC")!

private func limit(_ kind: String, _ percent: Double, resetsIn seconds: TimeInterval? = nil)
    -> AgentUsage.RateLimit {
    .init(kind: kind, percentUsed: percent, resetsAt: seconds.map { t0.addingTimeInterval($0) })
}

@Test func accountLimitsKeepTheNewestReportPerAccount() {
    var limits = AccountLimits()
    let first = limits.record(accountID: "work", limits: [limit("five_hour", 14)], observedAt: t0)
    #expect(first)
    // An older report, from a pane that was slower to write, changes nothing.
    let stale = limits.record(accountID: "work", limits: [limit("five_hour", 9)],
                              observedAt: t0.addingTimeInterval(-60))
    #expect(!stale)
    #expect(limits.windows(for: "work", now: t0).map(\.percentUsed) == [14])
    // Another account is its own reading.
    limits.record(accountID: "@default", limits: [limit("five_hour", 80)], observedAt: t0)
    #expect(limits.windows(for: "@default", now: t0).map(\.percentUsed) == [80])
    #expect(limits.windows(for: "nobody", now: t0).isEmpty)
}

@Test func accountLimitsReportOnlyWholePointChanges() {
    var limits = AccountLimits()
    limits.record(accountID: "work", limits: [limit("five_hour", 14.2)], observedAt: t0)
    let ticked = limits.record(accountID: "work", limits: [limit("five_hour", 14.4)],
                               observedAt: t0.addingTimeInterval(1))
    let moved = limits.record(accountID: "work", limits: [limit("five_hour", 15.1)],
                              observedAt: t0.addingTimeInterval(2))
    #expect(!ticked)
    #expect(moved)
}

@Test func accountLimitsIgnoreAReportWithNoWindows() {
    // The harness reports none before its first response; that must not wipe
    // what another pane on the same account already said.
    var limits = AccountLimits()
    limits.record(accountID: "work", limits: [limit("five_hour", 40)], observedAt: t0)
    let empty = limits.record(accountID: "work", limits: [], observedAt: t0.addingTimeInterval(5))
    #expect(!empty)
    #expect(limits.windows(for: "work", now: t0).count == 1)
}

@Test func accountLimitsDropAWindowThatHasReset() {
    var limits = AccountLimits()
    limits.record(accountID: "work",
                  limits: [limit("five_hour", 92, resetsIn: 600), limit("seven_day", 30, resetsIn: 86_400)],
                  observedAt: t0)
    #expect(limits.windows(for: "work", now: t0).count == 2)
    #expect(limits.windows(for: "work", now: t0.addingTimeInterval(601)).map(\.kind) == ["seven_day"])
}

@Test func accountLimitsForgetRemovedAccountsAndRoundTrip() throws {
    var limits = AccountLimits()
    limits.record(accountID: "work", limits: [limit("five_hour", 40, resetsIn: 600)], observedAt: t0)
    limits.record(accountID: "gone", limits: [limit("five_hour", 99)], observedAt: t0)
    limits.prune(keeping: ["work", "@default"])
    #expect(limits.windows(for: "gone", now: t0).isEmpty)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-limits-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AccountLimitsStore(directory: directory)
    #expect(store.load() == AccountLimits())   // nothing there yet
    try store.save(limits)
    #expect(store.load() == limits)
}

@Test func accountLimitLabelStaysQuietBelowTheThreshold() throws {
    let label = try #require(AccountLimitLabel(windows: [
        .init(kind: "seven_day", percentUsed: 12), .init(kind: "five_hour", percentUsed: 14.4),
    ], timeZone: utc))
    #expect(label.chip == nil)
    #expect(label.level == .normal)
    #expect(label.summary == "5h 14% · 7d 12%")
    #expect(AccountLimitLabel(windows: []) == nil)
}

@Test func accountLimitLabelShowsTheHighestWindowOnceItMatters() throws {
    let attention = try #require(AccountLimitLabel(windows: [
        .init(kind: "five_hour", percentUsed: 82), .init(kind: "seven_day", percentUsed: 40),
    ], timeZone: utc))
    #expect(attention.chip == "5h 82%")
    #expect(attention.level == .attention)

    let critical = try #require(AccountLimitLabel(windows: [
        .init(kind: "five_hour", percentUsed: 30),
        .init(kind: "seven_day", percentUsed: 96, resetsAt: t0),
    ], timeZone: utc))
    #expect(critical.chip == "7d 96%")
    #expect(critical.level == .critical)
    // A window that is nearly spent says when it comes back.
    #expect(critical.summary == "5h 30% · 7d 96% (resets Sat 04:00)")
}

@Test func accountLimitLabelNamesAnUnknownWindowByItsKind() throws {
    let label = try #require(AccountLimitLabel(windows: [
        .init(kind: "spend_limit", percentUsed: 71), .init(kind: "weekly_opus", percentUsed: 5),
    ], timeZone: utc))
    #expect(label.chip == "spend 71%")
    #expect(label.summary == "spend 71% · weekly_opus 5%")
}
