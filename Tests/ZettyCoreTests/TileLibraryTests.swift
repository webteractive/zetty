import Foundation
import Testing
@testable import ZettyCore

private func library(_ names: String...) -> TileProfileFile {
    TileProfileFile(profiles: names.map { TileProfile(name: $0, root: .slot) })
}

private func slot(_ name: String, tab: UUID = UUID()) -> TileSlot {
    TileSlot(projectRoot: "/tmp/\(name)", tabID: tab, label: "\(name) / main")
}

// MARK: - Library

@Test func viewsAreFoundByNameIgnoringCase() {
    let lib = library("Morning", "Review")
    #expect(lib.profile(named: "morning")?.name == "Morning")
    #expect(lib.profile(named: "nope") == nil)
}

@Test func anUnknownViewNamesTheKnownOnes() {
    let lib = library("Morning", "Review")
    #expect(throws: TileLibraryError.unknownView("x", known: ["Morning", "Review"])) {
        try lib.requireProfile(named: "x")
    }
}

@Test func theDefaultNameSkipsTakenOnes() {
    // Two views, so the count says "Tiles 3" — but that one is taken.
    let lib = library("Tiles 3", "Other")
    #expect(lib.nextDefaultName() == "Tiles 4")
}

@Test func renamingRejectsBlankAndCollidingNames() {
    var lib = library("Morning", "Review")
    let id = lib.profiles[0].id
    #expect(throws: TileLibraryError.blankName) { try lib.rename(id: id, to: "   ") }
    #expect(throws: TileLibraryError.duplicateName("Review")) { try lib.rename(id: id, to: "review") }
    #expect(lib.profiles[0].name == "Morning")
}

@Test func renamingAViewToACaseChangeOfItselfIsAllowed() throws {
    var lib = library("Morning")
    try lib.rename(id: lib.profiles[0].id, to: " MORNING ")
    #expect(lib.profiles[0].name == "MORNING")
}

@Test func duplicatingCopiesSlotsUnderAFreshIdRightAfterTheSource() throws {
    var lib = library("Morning", "Review")
    lib.profiles[0].attach(slot("a"), at: 0)
    let source = lib.profiles[0]
    let copy = try #require(try lib.duplicate(id: source.id))
    #expect(copy.id != source.id)
    #expect(copy.name == "Morning copy")
    #expect(copy.slots == source.slots)
    #expect(copy.root == source.root)
    #expect(lib.profiles.map(\.name) == ["Morning", "Morning copy", "Review"])
    // A second copy does not collide with the first.
    #expect(try lib.duplicate(id: source.id)?.name == "Morning copy 2")
}

@Test func duplicatingUnderATakenNameIsRefused() {
    var lib = library("Morning", "Review")
    #expect(throws: TileLibraryError.duplicateName("Review")) {
        try lib.duplicate(id: lib.profiles[0].id, name: "Review")
    }
    #expect(lib.profiles.count == 2)
}

@Test func deletingRemovesOnlyThatView() {
    var lib = library("Morning", "Review")
    let removed = lib.delete(id: lib.profiles[0].id)
    #expect(removed?.name == "Morning")
    #expect(lib.profiles.map(\.name) == ["Review"])
    #expect(lib.delete(id: UUID()) == nil)
}

// MARK: - Placement

@Test func aTabAlreadyInTheViewStaysWhereItIs() {
    let tab = UUID()
    var p = TileProfile(name: "v", grid: TilesGrid(columns: 2, rows: 1))
    p.attach(slot("a", tab: tab), at: 1)
    #expect(TilePlacement.place(tabID: tab, in: p, focusedSlot: 0) == .existing(1))
    let before = p
    p.place(slot("a", tab: tab), focusedSlot: 0)
    #expect(p == before)
}

@Test func theFirstHoleIsFilledBeforeAnythingSplits() {
    var p = TileProfile(name: "v", grid: TilesGrid(columns: 3, rows: 1))
    p.attach(slot("a"), at: 0)
    let placement = p.place(slot("b"), focusedSlot: 0)
    #expect(placement == .hole(1))
    #expect(p.capacity == 3)
    #expect(p.slots[1]?.projectRoot == "/tmp/b")
}

@Test func aFullViewSplitsTheFocusedSlotAndFillsTheNewHalf() {
    var p = TileProfile(name: "v", grid: TilesGrid(columns: 2, rows: 1))
    p.attach(slot("a"), at: 0)
    p.attach(slot("b"), at: 1)
    let placement = p.place(slot("c"), focusedSlot: 0)
    #expect(placement == .split(from: 0, into: 1))
    #expect(p.capacity == 3)
    // The new leaf sits right after the one that split; later slots shift on.
    #expect(p.slots.map { $0?.projectRoot } == ["/tmp/a", "/tmp/c", "/tmp/b"])
}

@Test func withNothingFocusedTheLastSlotSplits() {
    var p = TileProfile(name: "v", root: .slot)
    p.attach(slot("a"), at: 0)
    #expect(p.place(slot("b"), focusedSlot: nil) == .split(from: 0, into: 1))
    #expect(p.slots.map { $0?.projectRoot } == ["/tmp/a", "/tmp/b"])
}

@Test func holesPastTheLayoutAreNotHoles() {
    // A library written before layouts were trees can hold more slots than
    // leaves; an empty one out there is not on screen.
    var p = TileProfile(name: "v", root: .slot, slots: [slot("a"), nil])
    #expect(p.capacity == 1)
    #expect(p.place(slot("b"), focusedSlot: 0) == .split(from: 0, into: 1))
}
