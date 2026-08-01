import Foundation
import Testing
@testable import ZettyCore

private func pane(_ backed: Bool = true) -> BackgroundPanePolicy.Pane {
    BackgroundPanePolicy.Pane(id: UUID(), isSessionBacked: backed)
}

@Test func disabledKeepsEverythingAttached() {
    let p = BackgroundPanePolicy.Project(isActive: false, idleFor: 9999, panes: [pane(), pane()])
    #expect(BackgroundPanePolicy.releasableSurfaces(projects: [p], freeAfter: 0).isEmpty)
    #expect(BackgroundPanePolicy.releasableSurfaces(projects: [p], freeAfter: -1).isEmpty)
}

@Test func theActiveProjectIsNeverReleased() {
    let p = BackgroundPanePolicy.Project(isActive: true, idleFor: 9999, panes: [pane(), pane()])
    #expect(BackgroundPanePolicy.releasableSurfaces(projects: [p], freeAfter: 60).isEmpty)
}

@Test func aPaneWithoutAPreservedSessionIsNeverReleased() {
    // Freeing a plain shell's surface kills the process — the one thing this
    // policy must never do, no matter how long the project has been idle.
    let p = BackgroundPanePolicy.Project(
        isActive: false, idleFor: 9999, panes: [pane(false), pane(false)])
    #expect(BackgroundPanePolicy.releasableSurfaces(projects: [p], freeAfter: 60).isEmpty)
}

@Test func mixedProjectReleasesOnlyItsSessionBackedPanes() {
    let backed = pane(true)
    let plain = pane(false)
    let p = BackgroundPanePolicy.Project(isActive: false, idleFor: 120, panes: [backed, plain])
    let releasable = BackgroundPanePolicy.releasableSurfaces(projects: [p], freeAfter: 60)
    #expect(releasable == [backed.id])
}

@Test func idleWindowMustBeReachedBeforeRelease() {
    let a = pane()
    let tooFresh = BackgroundPanePolicy.Project(isActive: false, idleFor: 59, panes: [a])
    #expect(BackgroundPanePolicy.releasableSurfaces(projects: [tooFresh], freeAfter: 60).isEmpty)

    let b = pane()
    let atBoundary = BackgroundPanePolicy.Project(isActive: false, idleFor: 60, panes: [b])
    #expect(BackgroundPanePolicy.releasableSurfaces(projects: [atBoundary], freeAfter: 60) == [b.id])
}

@Test func keepSetSpansEveryDescribedPane() {
    // The caller drives `prune` with the keep-set, so it must name every pane
    // that isn't being deliberately released.
    let active = BackgroundPanePolicy.Project(isActive: true, idleFor: 0, panes: [pane(), pane()])
    let idle = BackgroundPanePolicy.Project(isActive: false, idleFor: 300, panes: [pane(), pane(false)])
    let keep = BackgroundPanePolicy.surfacesToKeepAttached(projects: [active, idle], freeAfter: 60)
    let all = Set((active.panes + idle.panes).map(\.id))
    let released = BackgroundPanePolicy.releasableSurfaces(projects: [active, idle], freeAfter: 60)
    #expect(keep.union(released) == all)
    #expect(keep.intersection(released).isEmpty)
    #expect(released.count == 1)          // only the idle project's backed pane
}

@Test func severalIdleProjectsAllRelease() {
    let ps = (0..<3).map { _ in
        BackgroundPanePolicy.Project(isActive: false, idleFor: 600, panes: [pane(), pane()])
    }
    #expect(BackgroundPanePolicy.releasableSurfaces(projects: ps, freeAfter: 60).count == 6)
    #expect(BackgroundPanePolicy.surfacesToKeepAttached(projects: ps, freeAfter: 60).isEmpty)
}
