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
