import Foundation
import Testing
@testable import ZettyCore

private let surface = UUID(uuidString: "045C5269-31AD-4EE6-9698-096263D638A5")!

@Test func aRecordRoundTrips() throws {
    let record = HandoffRecord(surface: surface, agent: .claude, sessionID: "c3304ad1-f1bd",
                               cwd: "/Users/me/app", accountID: "work",
                               requestedAt: Date(timeIntervalSince1970: 1_000))
    let data = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(HandoffRecord.self, from: data) == record)
}

@Test func filesAreNamedAfterTheSurface() {
    #expect(HandoffPaths.directory(home: "/Users/me") == "/Users/me/.zetty/handoffs")
    #expect(HandoffPaths.record(for: surface, home: "/Users/me")
            == "/Users/me/.zetty/handoffs/045C5269-31AD-4EE6-9698-096263D638A5.json")
    #expect(HandoffPaths.surfaceID(fromFileName: "045C5269-31AD-4EE6-9698-096263D638A5.json") == surface)
    #expect(HandoffPaths.surfaceID(fromFileName: "notes.json") == nil)
}

@Test func anAgentQuietForOverAWeekGetsNoHandoffOnAnAutomaticHibernate() {
    let week: TimeInterval = 7 * 86_400
    #expect(HandoffPolicy.writesHandoff(manual: false, agentQuietFor: week))
    #expect(!HandoffPolicy.writesHandoff(manual: false, agentQuietFor: week + 1))
    // By hand always writes one, and an unknown age is not "old".
    #expect(HandoffPolicy.writesHandoff(manual: true, agentQuietFor: week * 10))
    #expect(HandoffPolicy.writesHandoff(manual: false, agentQuietFor: nil))
}

// MARK: - A handoff belongs to its project

// A project wakes as one pane and the other handoffs wait for a new tab or
// split, so the pane a handoff came from is gone while it waits.
@Test func aHandoffWaitsInItsProjectUntilItIsPicked() {
    let project = "/Users/me/app", other = "/Users/me/site"
    var record = HandoffRecord(surface: surface, agent: .claude, sessionID: "s", cwd: "/p", accountID: nil,
                               requestedAt: Date(timeIntervalSince1970: 0), project: project,
                               title: "Fix the importer")
    #expect(record.isWaiting(in: project, panes: []), "its pane need not exist any more")
    #expect(!record.isWaiting(in: other, panes: [surface]))
    #expect(record.label == "Claude · Fix the importer")
    // On its way back already: a wake line is queued for it.
    record.wake = .resume
    #expect(!record.isWaiting(in: project, panes: []))
}

// A project's id is new at every launch, and records filed under one were
// swept as orphans by the next. The key it is filed under is the one its
// settings use, which is the same string before and after.
@Test func theProjectAHandoffNamesSurvivesBeingWrittenAndReadBack() throws {
    let record = HandoffRecord(surface: surface, agent: .claude, sessionID: "s", cwd: "/p", accountID: nil,
                               requestedAt: Date(timeIntervalSince1970: 0), project: "/Users/me/app")
    let decoded = try JSONDecoder().decode(HandoffRecord.self, from: JSONEncoder().encode(record))
    #expect(decoded.isWaiting(in: "/Users/me/app", panes: []))
}

// A record written before it named its project is its pane's.
@Test func anOlderRecordBelongsToThePaneItCameFrom() throws {
    let old = HandoffRecord(surface: surface, agent: .codex, sessionID: "s", cwd: "/p", accountID: nil,
                            requestedAt: Date(timeIntervalSince1970: 0))
    #expect(old.isWaiting(in: "/any", panes: [surface]))
    #expect(!old.isWaiting(in: "/any", panes: []))
    #expect(old.label == "Codex")
    let decoded = try JSONDecoder().decode(HandoffRecord.self, from: JSONEncoder().encode(old))
    #expect(decoded.project == nil && decoded.title == nil)
}

// A pane's title carries the glyph its harness draws in front of it, and a
// transcript's does not: listed together they read as two kinds of thing.
@Test func aLabelDropsWhatTheHarnessDrewInFrontOfTheTitle() {
    func label(_ title: String?) -> String {
        HandoffRecord(surface: surface, agent: .claude, sessionID: "s", cwd: "/p", accountID: nil,
                      requestedAt: Date(timeIntervalSince1970: 0), title: title).label
    }
    #expect(label("✳ Release notes in notes.md") == "Claude · Release notes in notes.md")
    #expect(label("⠋  Importer.swift retry logic") == "Claude · Importer.swift retry logic")
    #expect(label("Flaky SyncTests.swift test") == "Claude · Flaky SyncTests.swift test")
    #expect(label("✳ ") == "Claude")
    #expect(label(nil) == "Claude")
}

