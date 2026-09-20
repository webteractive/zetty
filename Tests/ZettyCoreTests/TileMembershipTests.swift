import Foundation
import Testing
@testable import ZettyCore

private let a = UUID()
private let b = UUID()
private let c = UUID()

private func entries(_ pairs: [(UUID, Bool)]) -> [TileEntry] {
    pairs.map { TileEntry(surfaceID: $0.0, isBusy: $0.1) }
}

@Test func anEmptyPreviousTakesBusyOrder() {
    let result = TileMembership.update(previous: [], busy: [a, b], existing: [a, b, c])
    #expect(result == entries([(a, true), (b, true)]))
}

@Test func anIdlePaneKeepsItsIndexAndGoesIdle() {
    let previous = entries([(a, true), (b, true), (c, true)])
    let result = TileMembership.update(previous: previous, busy: [a, c], existing: [a, b, c])
    #expect(result == entries([(a, true), (b, false), (c, true)]))
}

@Test func aNewlyBusyPaneAppends() {
    let previous = entries([(a, true)])
    let result = TileMembership.update(previous: previous, busy: [c, a], existing: [a, b, c])
    #expect(result.map(\.surfaceID) == [a, c])
}

@Test func aClosedPaneIsDropped() {
    let previous = entries([(a, true), (b, false)])
    let result = TileMembership.update(previous: previous, busy: [a], existing: [a])
    #expect(result == entries([(a, true)]))
}

@Test func anIdlePaneThatBecomesBusyAgainDoesNotMove() {
    let previous = entries([(a, true), (b, false), (c, true)])
    let result = TileMembership.update(previous: previous, busy: [a, b, c], existing: [a, b, c])
    #expect(result.map(\.surfaceID) == [a, b, c])
    #expect(result.map(\.isBusy) == [true, true, true])
}

@Test func aBusyPaneThatNoLongerExistsIsNeverAdded() {
    let result = TileMembership.update(previous: [], busy: [a, b], existing: [a])
    #expect(result == entries([(a, true)]))
}

@Test func appendedPanesFollowBusyOrderNotUUIDOrder() {
    let result = TileMembership.update(previous: [], busy: [c, b, a], existing: [a, b, c])
    #expect(result.map(\.surfaceID) == [c, b, a])
}
