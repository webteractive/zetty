import Foundation
import Testing
@testable import ZettyCore

private let a = UUID(), b = UUID(), c = UUID()

@Test func aSurfaceLeavingTheLayoutIsHeldWhileItsSessionEnds() {
    // b was closed: still live in the registry, no longer retained.
    #expect(SurfaceTeardownGate.held(live: [a, b], retained: [a], released: [], canEndSessions: true) == [b])
}

@Test func nothingIsHeldWhenNothingLeaves() {
    #expect(SurfaceTeardownGate.held(live: [a, b], retained: [a, b], released: [], canEndSessions: true).isEmpty)
}

@Test func aSurfaceWhoseTeardownFinishedIsFreedNotHeldAgain() {
    // The completion's own rebuild must free it, or it loops forever.
    #expect(SurfaceTeardownGate.held(live: [a, b], retained: [a], released: [b], canEndSessions: true).isEmpty)
}

@Test func withoutZmxThereIsNoSessionToEndFirst() {
    #expect(SurfaceTeardownGate.held(live: [a, b], retained: [a], released: [], canEndSessions: false).isEmpty)
}

@Test func onlyTheClosingSurfacesAreHeld() {
    #expect(SurfaceTeardownGate.held(live: [a, b, c], retained: [a], released: [c], canEndSessions: true) == [b])
}
