import Foundation
import Testing
@testable import ZettyCore

private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

@Test func unreadIsTheAttentionSetMinusAcknowledged() {
    let inbox = AttentionInbox()
    inbox.update(needsAttention: [a, b])
    #expect(inbox.unread == [a, b])

    inbox.acknowledge(a)
    #expect(inbox.unread == [b])
    #expect(inbox.unreadCount == 1)
}

@Test func acknowledgeAllEmptiesUnread() {
    let inbox = AttentionInbox()
    inbox.update(needsAttention: [a, b])
    inbox.acknowledgeAll()
    #expect(inbox.unread.isEmpty)
    #expect(inbox.unreadCount == 0)
}

@Test func attentionEpisodeEndResetsTheReadMark() {
    let inbox = AttentionInbox()
    inbox.update(needsAttention: [a])
    inbox.acknowledge(a)
    #expect(inbox.unread.isEmpty)

    // The agent gets input (leaves needsAttention), then needs attention again:
    // that's a NEW episode — it must show as unread.
    inbox.update(needsAttention: [])
    inbox.update(needsAttention: [a])
    #expect(inbox.unread == [a])
}

@Test func acknowledgingAnUnknownPaneIsHarmless() {
    let inbox = AttentionInbox()
    inbox.update(needsAttention: [a])
    inbox.acknowledge(b)
    #expect(inbox.unread == [a])
}

@Test func sidebarWidthClampsToBounds() {
    #expect(SidebarMetrics.clampWidth(100) == SidebarMetrics.minWidth)
    #expect(SidebarMetrics.clampWidth(999) == SidebarMetrics.maxWidth)
    #expect(SidebarMetrics.clampWidth(300) == 300)
    #expect(SidebarMetrics.defaultWidth == 244)
}

// MARK: - Persistence across relaunch

@Test func snapshotRoundTrips() throws {
    let inbox = AttentionInbox()
    inbox.update(needsAttention: [a, b])
    inbox.acknowledge(a)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = AttentionInboxStore(directory: dir)
    #expect(store.load() == nil)
    try store.save(inbox.snapshot)
    let restored = try #require(store.load())
    #expect(Set(restored.needsAttention) == [a, b])
    #expect(restored.acknowledged == [a])
}

@Test func restoredReadMarkSurvivesWhenStillWaiting() {
    let inbox = AttentionInbox(snapshot: AttentionInboxSnapshot(needsAttention: [a], acknowledged: [a]))
    inbox.settleAfterReplay(needsAttention: [a])
    #expect(inbox.unread.isEmpty)
}

@Test func restoredEntryDropsWhenNoLongerWaiting() {
    let inbox = AttentionInbox(snapshot: AttentionInboxSnapshot(needsAttention: [a], acknowledged: []))
    inbox.settleAfterReplay(needsAttention: [])
    #expect(inbox.unread.isEmpty)
    #expect(inbox.snapshot.needsAttention.isEmpty)
}

@Test func unreadSurvivorCountsAfterRestore() {
    let inbox = AttentionInbox(snapshot: AttentionInboxSnapshot(needsAttention: [a], acknowledged: []))
    inbox.settleAfterReplay(needsAttention: [a])
    #expect(inbox.unreadCount == 1)
}

@Test func replayedWaitNotInTheSnapshotIsNotNew() {
    // Replay restored a yellow the inbox never recorded (e.g. the first launch
    // after upgrading): it is still true, but it isn't news — no badge.
    let inbox = AttentionInbox(snapshot: AttentionInboxSnapshot(needsAttention: [], acknowledged: []))
    inbox.settleAfterReplay(needsAttention: [b])
    #expect(inbox.unread.isEmpty)
    // Its next episode is news again.
    inbox.update(needsAttention: [])
    inbox.update(needsAttention: [b])
    #expect(inbox.unread == [b])
}

@Test func reopenMakesAnEpisodeUnreadAgain() {
    let inbox = AttentionInbox()
    inbox.update(needsAttention: [a])
    inbox.acknowledge(a)
    #expect(inbox.unread.isEmpty)
    inbox.reopen(a)
    inbox.update(needsAttention: [a])
    #expect(inbox.unread == [a])
}

@Test func aLiveRequestDuringTheReplayIsStillNews() {
    // Raised by a live report in the moments before the startup replay
    // finished: it isn't replayed state, so it isn't marked read.
    let inbox = AttentionInbox(snapshot: AttentionInboxSnapshot(needsAttention: [], acknowledged: []))
    inbox.settleAfterReplay(needsAttention: [a, b], raisedLive: [b])
    #expect(inbox.unread == [b])
}

/// A hibernated project's panes are not waiting on anyone, whatever the
/// board last heard: hibernating a waiting project, or a replay into one at
/// launch, kept the bell and the Dock badge counting it (release review,
/// 2026-11-20).
@Test func aHibernatedProjectsPanesAreNotWaiting() {
    let awake = ProjectRuntime(name: "awake", rootPath: "/a")
    let asleep = ProjectRuntime(name: "asleep", rootPath: "/b", isHibernated: true)
    let ids = [awake, asleep].flatMap { $0.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) } }
    #expect(ids.count == 2)
    let waiting = AttentionInbox.waitingPanes(in: [awake, asleep]) { _ in .needsAttention }
    #expect(waiting == Set(awake.tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }))
}
