import Foundation
import Testing
@testable import ZettyCore

private let owned = UUID()
private let dormant = UUID()

private func session(for id: UUID) -> String { SessionPersistence.sessionName(for: id) }

@Test func anOwnedSessionCarriesItsPane() {
    let rows = TaskInventory.rows(
        sessions: [session(for: owned): 501],
        owned: [owned],
        paneLabels: [owned: "zetty / main"],
        running: [session(for: owned): "claude"],
        loads: [:])
    #expect(rows.count == 1)
    #expect(rows[0].surfaceID == owned)
    #expect(rows[0].paneLabel == "zetty / main")
    #expect(rows[0].isOrphan == false)
}

@Test func aSessionNoSurfaceClaimsIsAnOrphan() {
    let rows = TaskInventory.rows(
        sessions: ["zetty-deadbeef": 700],
        owned: [owned], paneLabels: [:], running: [:], loads: [:])
    #expect(rows[0].isOrphan)
    #expect(rows[0].paneLabel == nil)
}

@Test func aHibernatedProjectsSessionIsOwnedNotOrphaned() {
    // The caller must pass WorkspaceModel.sessionOwnerSurfaceIDs, which spans
    // hibernated projects. Passing allSurfaceIDs instead would mark every
    // dormant project's session an orphan and invite killing it.
    let rows = TaskInventory.rows(
        sessions: [session(for: dormant): 800],
        owned: [owned, dormant],
        paneLabels: [:], running: [:], loads: [:])
    #expect(rows[0].isOrphan == false)
    #expect(rows[0].surfaceID == dormant)
}

@Test func rowsSortByCpuDescending() {
    let hot = "zetty-aaaaaaaa", cold = "zetty-bbbbbbbb"
    let rows = TaskInventory.rows(
        sessions: [hot: 1, cold: 2], owned: [], paneLabels: [:], running: [:],
        loads: [hot: SessionLoad(cpuPercent: 90, rssBytes: 0, processCount: 1),
                cold: SessionLoad(cpuPercent: 2, rssBytes: 0, processCount: 1)])
    #expect(rows.map(\.session) == [hot, cold])
}

@Test func rowsWithNoRateYetSortLastAndDoNotOutrankIdle() {
    let measured = "zetty-aaaaaaaa", unmeasured = "zetty-bbbbbbbb"
    let rows = TaskInventory.rows(
        sessions: [measured: 1, unmeasured: 2], owned: [], paneLabels: [:], running: [:],
        loads: [measured: SessionLoad(cpuPercent: 0, rssBytes: 0, processCount: 1),
                unmeasured: .none])
    #expect(rows.map(\.session) == [measured, unmeasured])
}

@Test func equalRowsFallBackToSessionNameSoTheOrderIsStable() {
    // The list refreshes every few seconds; an unstable sort makes rows swap
    // under the pointer mid-click.
    let a = "zetty-aaaaaaaa", b = "zetty-bbbbbbbb"
    let loads = [a: SessionLoad(cpuPercent: 5, rssBytes: 0, processCount: 1),
                 b: SessionLoad(cpuPercent: 5, rssBytes: 0, processCount: 1)]
    let rows = TaskInventory.rows(sessions: [a: 1, b: 2], owned: [],
                                  paneLabels: [:], running: [:], loads: loads)
    #expect(rows.map(\.session) == [a, b])
}

@Test func anUnknownForegroundFallsBackToAShellLabel() {
    let rows = TaskInventory.rows(sessions: ["zetty-aaaaaaaa": 1], owned: [],
                                  paneLabels: [:], running: [:], loads: [:])
    #expect(rows[0].running == "shell")
}

@Test func aProbedIdlePaneReadsAsIdleNotAsBlank() {
    // The foreground probe stores "" for "probed, and found a shell" — a
    // meaningful value, not a missing one. Passing it through renders an
    // empty cell that looks like a rendering bug.
    let rows = TaskInventory.rows(sessions: ["zetty-aaaaaaaa": 1], owned: [],
                                  paneLabels: [:],
                                  running: ["zetty-aaaaaaaa": ""], loads: [:])
    #expect(rows[0].running == "shell")
}

// MARK: - Grouping by project

private func row(_ id: UUID?, _ session: String, cpu: Double? = nil, rss: Int64 = 0) -> TaskRow {
    TaskRow(session: session, surfaceID: id, paneLabel: nil, running: "shell",
            load: SessionLoad(cpuPercent: cpu, rssBytes: rss, processCount: 1))
}

private func project(_ name: String, _ surfaces: [UUID], canHibernate: Bool = true,
                     hibernated: Bool = false) -> TaskProjectRef {
    TaskProjectRef(id: UUID(), name: name, surfaceIDs: Set(surfaces),
                   canHibernate: canHibernate, isHibernated: hibernated)
}

@Test func groupsFollowProjectOrderNotLoad() {
    // Sidebar order, so a group's Hibernate button never slides away while the
    // pointer is on its way to it.
    let a = UUID(), b = UUID()
    let api = project("api", [a]), web = project("web", [b])
    let groups = TaskInventory.groups(
        rows: [row(b, "zetty-b", cpu: 90), row(a, "zetty-a", cpu: 1)],
        projects: [api, web])
    #expect(groups.map(\.title) == ["api", "web"])
    #expect(groups[0].owner == .project(api.id))
}

@Test func rowsKeepTheirIncomingOrderInsideAGroup() {
    let hot = UUID(), cold = UUID()
    let groups = TaskInventory.groups(
        rows: [row(hot, "zetty-hot", cpu: 50), row(cold, "zetty-cold", cpu: 1)],
        projects: [project("api", [cold, hot])])
    #expect(groups[0].rows.map(\.session) == ["zetty-hot", "zetty-cold"])
}

@Test func aProjectWithNoSessionsGetsNoGroup() {
    let a = UUID()
    let groups = TaskInventory.groups(
        rows: [row(a, "zetty-a")],
        projects: [project("empty", []), project("api", [a])])
    #expect(groups.map(\.title) == ["api"])
}

@Test func orphansCollectInATrailingGroupWithNoHibernate() {
    let a = UUID()
    let groups = TaskInventory.groups(
        rows: [row(nil, "zetty-dead"), row(a, "zetty-a")],
        projects: [project("api", [a])])
    #expect(groups.map(\.title) == ["api", "Orphaned"])
    #expect(groups[1].owner == .orphaned)
    #expect(groups[1].canHibernate == false)
}

@Test func homeAndScratchOfferNoHibernate() {
    let h = UUID()
    let groups = TaskInventory.groups(
        rows: [row(h, "zetty-h")],
        projects: [project("Home", [h], canHibernate: false)])
    #expect(groups[0].canHibernate == false)
}

@Test func aHibernatedProjectWithLiveSessionsReadsAsHibernating() {
    // Its sessions are still ending (the teardown's grace period), so it shows
    // — but hibernating it again would be a dead button.
    let a = UUID()
    let groups = TaskInventory.groups(
        rows: [row(a, "zetty-a")],
        projects: [project("api", [a], hibernated: true)])
    #expect(groups[0].isHibernating)
    #expect(groups[0].canHibernate == false)
}

@Test func groupTotalsSumMeasuredLoadOnly() {
    let a = UUID(), b = UUID(), c = UUID()
    let groups = TaskInventory.groups(
        rows: [row(a, "zetty-a", cpu: 10, rss: 100),
               row(b, "zetty-b", cpu: 2.5, rss: 50),
               row(c, "zetty-c", cpu: nil, rss: 25)],
        projects: [project("api", [a, b, c])])
    let expectedRSS: Int64 = 175
    #expect(groups[0].cpuPercent == 12.5)
    #expect(groups[0].rssBytes == expectedRSS)
}

@Test func aGroupWithNothingMeasuredHasNoCpu() {
    let a = UUID()
    let groups = TaskInventory.groups(rows: [row(a, "zetty-a")],
                                      projects: [project("api", [a])])
    #expect(groups[0].cpuPercent == nil)
}
