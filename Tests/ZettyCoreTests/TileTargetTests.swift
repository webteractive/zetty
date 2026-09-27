import Foundation
import Testing
@testable import ZettyCore

private let paneSlot = TileSlot(projectRoot: "/a", tabID: UUID(), label: "a / one")
private let otherSlot = TileSlot(projectRoot: "/b", tabID: UUID(), label: "b / two")

// MARK: - A slot aimed at before a modal step

@Test func anUntouchedHoleIsStillTheTarget() {
    let profile = TileProfile(name: "v", root: .uniform(columns: 2, rows: 1))
    #expect(profile.isStillTarget(1, holding: nil))
}

@Test func aHoleFilledMeanwhileIsNoLongerTheTarget() {
    var profile = TileProfile(name: "v", root: .uniform(columns: 2, rows: 1))
    profile.attach(otherSlot, at: 1)
    #expect(!profile.isStillTarget(1, holding: nil))
}

@Test func aSlotCollapsedAwayIsNoLongerTheTarget() {
    // The index is past the layout now: attaching there would be off screen.
    let profile = TileProfile(name: "v", root: .slot)
    #expect(!profile.isStillTarget(1, holding: nil))
}

@Test func anUnchangedMissingSlotIsStillTheTarget() {
    // Reattach on a missing slot aims at a non-empty slot, and must replace it.
    var profile = TileProfile(name: "v", root: .uniform(columns: 2, rows: 1))
    profile.attach(paneSlot, at: 0)
    #expect(profile.isStillTarget(0, holding: paneSlot))
    #expect(!profile.isStillTarget(0, holding: otherSlot))
}

@Test func aHolePastTheStoredSlotsButInsideTheLayoutIsStillTheTarget() {
    var profile = TileProfile(name: "v", root: .uniform(columns: 3, rows: 1))
    profile.slots = []
    #expect(profile.isStillTarget(2, holding: nil))
}
