import Foundation
import Testing
@testable import ZettyCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func workspace(projects: Int, hibernated: Int, needsYou: Int) -> StatusSnapshot {
    var remainingAttention = needsYou
    let list = (0..<projects).map { i -> StatusSnapshot.Project in
        let pane = StatusSnapshot.Pane(
            id: "p\(i)", title: nil, cwd: nil, tool: nil,
            agentStatus: remainingAttention > 0 ? AgentStatus.needsAttention.rawValue : AgentStatus.idle.rawValue,
            isFocused: false, live: true)
        if remainingAttention > 0 { remainingAttention -= 1 }
        return .init(name: "project\(i)", isActive: i == 0, hibernated: i < hibernated, id: "id\(i)",
                     tabs: [.init(title: "t", isActive: true, panes: [pane])])
    }
    return StatusSnapshot(projects: list)
}

private func mini(projects: Int, hibernated: Int, needsYou: Int) -> RemoteMachine {
    RemoteMachine(stableID: "nMINI", name: "Mac mini", state: .online, lastSeen: t0,
                  workspace: workspace(projects: projects, hibernated: hibernated, needsYou: needsYou))
}

private func offline(seen: Date?) -> RemoteMachine {
    RemoteMachine(stableID: "nSTUDIO", name: "Studio", state: .offline, lastSeen: seen, workspace: nil)
}

private func machine(_ state: RemoteMachine.State) -> RemoteMachine {
    RemoteMachine(stableID: "n", name: "Studio", state: state, lastSeen: nil, workspace: nil)
}

@Test func onlineSummaryCountsAwakeProjectsAndWhatNeedsYou() {
    #expect(RemoteMachineSummary.text(for: mini(projects: 3, hibernated: 1, needsYou: 1), now: t0) == "2 · 1 needs you")
    #expect(RemoteMachineSummary.text(for: mini(projects: 2, hibernated: 0, needsYou: 0), now: t0) == "2")
}

@Test func needsYouCountsPanesWaitingOnTheUser() {
    #expect(mini(projects: 3, hibernated: 0, needsYou: 2).needsYouCount == 2)
    #expect(offline(seen: nil).needsYouCount == 0)
}

@Test func offlineSummarySaysWhenItWasLastSeen() {
    #expect(RemoteMachineSummary.text(for: offline(seen: t0.addingTimeInterval(-7200)), now: t0) == "offline · seen 2h ago")
    #expect(RemoteMachineSummary.text(for: offline(seen: t0.addingTimeInterval(-90)), now: t0) == "offline · seen 1m ago")
    #expect(RemoteMachineSummary.text(for: offline(seen: t0.addingTimeInterval(-30)), now: t0) == "offline · seen just now")
    #expect(RemoteMachineSummary.text(for: offline(seen: t0.addingTimeInterval(-3 * 86400)), now: t0) == "offline · seen 3d ago")
    #expect(RemoteMachineSummary.text(for: offline(seen: nil), now: t0) == "offline")
}

@Test func otherStatesReadPlainly() {
    #expect(RemoteMachineSummary.text(for: machine(.connecting), now: t0) == "connecting…")
    #expect(RemoteMachineSummary.text(for: machine(.needsUpdate(theirs: 2)), now: t0) == "needs update")
    #expect(RemoteMachineSummary.text(for: machine(.refused("Studio isn't a Mac")), now: t0) == "Studio isn't a Mac")
}

@Test func cacheRoundTripsAndComesBackOffline() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = RemoteMachineCache(url: url)
    cache.save([mini(projects: 2, hibernated: 0, needsYou: 0)])
    let back = cache.load()
    #expect(back.count == 1)
    #expect(back[0].state == .offline)
    #expect(back[0].workspace?.projects.count == 2)
    #expect(back[0].lastSeen == t0)
}

@Test func missingOrCorruptCacheIsEmpty() throws {
    let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    #expect(RemoteMachineCache(url: missing).load().isEmpty)
    let corrupt = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: corrupt) }
    try Data("x".utf8).write(to: corrupt)
    #expect(RemoteMachineCache(url: corrupt).load().isEmpty)
}

@Test func cacheIsReadableOnlyByTheUser() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    RemoteMachineCache(url: url).save([mini(projects: 1, hibernated: 0, needsYou: 0)])
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}
