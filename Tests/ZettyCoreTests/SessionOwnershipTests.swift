import Testing
import Foundation
@testable import ZettyCore

/// Session *ownership* is not the same question as which surfaces should be
/// attached. Hibernating tears a project's panes down and frees its sessions,
/// but only best-effort — it can't when zmx has gone missing, and a crash can
/// cut it short — so a hibernated project's surface may still have a session
/// behind it. Diffing against a hibernation-filtered set makes those look
/// orphaned and kills them on the next launch, unattended (auto-hibernation
/// needs no user action). Only sessions no project claims may be reaped.
@Test func sessionOwnersIncludeHibernatedProjects() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "awake", rootPath: "/awake"),
        ProjectRuntime(name: "sleeping", rootPath: "/sleeping"),
    ], activeIndex: 0)!
    ws.projects[1].isHibernated = true

    let awake = ws.projects[0].tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }
    let sleeping = ws.projects[1].tabList.trees.flatMap { $0.layout.surfaces.map(\.id) }
    #expect(!awake.isEmpty)
    #expect(!sleeping.isEmpty)

    let owners = ws.sessionOwnerSurfaceIDs
    for id in awake + sleeping {
        #expect(owners.contains(id))
    }
}

/// End-to-end on the pure layer: a hibernated project's session must NOT be
/// classified as an orphan.
@Test func hibernatedProjectSessionIsNotAnOrphan() {
    let ws = WorkspaceModel(restoring: [
        ProjectRuntime(name: "awake", rootPath: "/awake"),
        ProjectRuntime(name: "sleeping", rootPath: "/sleeping"),
    ], activeIndex: 0)!
    ws.projects[1].isHibernated = true

    let existing = ws.sessionOwnerSurfaceIDs.map(SessionPersistence.sessionName(for:))
        + ["zetty-deadbeef"]   // a genuine leftover
    let orphans = SessionPersistence.orphans(
        existing: existing,
        liveSurfaceIDs: ws.sessionOwnerSurfaceIDs)

    #expect(orphans == ["zetty-deadbeef"])
}
