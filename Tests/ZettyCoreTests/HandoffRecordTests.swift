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
    #expect(HandoffPaths.handoff(for: surface, home: "/Users/me")
            == "/Users/me/.zetty/handoffs/045C5269-31AD-4EE6-9698-096263D638A5.md")
    #expect(HandoffPaths.record(for: surface, home: "/Users/me")
            == "/Users/me/.zetty/handoffs/045C5269-31AD-4EE6-9698-096263D638A5.json")
    #expect(HandoffPaths.surfaceID(fromFileName: "045C5269-31AD-4EE6-9698-096263D638A5.md") == surface)
    #expect(HandoffPaths.surfaceID(fromFileName: "notes.md") == nil)
}

@Test func anAgentQuietForOverAWeekGetsNoHandoffOnAnAutomaticHibernate() {
    let week: TimeInterval = 7 * 86_400
    #expect(HandoffPolicy.writesHandoff(manual: false, agentQuietFor: week))
    #expect(!HandoffPolicy.writesHandoff(manual: false, agentQuietFor: week + 1))
    // By hand always writes one, and an unknown age is not "old".
    #expect(HandoffPolicy.writesHandoff(manual: true, agentQuietFor: week * 10))
    #expect(HandoffPolicy.writesHandoff(manual: false, agentQuietFor: nil))
}
