import Foundation
import Testing
@testable import ZettyCore

@Test func freeformIsTheOnlyBuiltIn() {
    // Every preset was reachable by splitting this one, so shipping seven
    // cards was seven ways of offering a shape you could make in two clicks.
    #expect(TileLayout.builtIns.map(\.name) == ["Freeform"])
    #expect(TileLayout.builtIns.first?.root == .slot)
}

@Test func splittingFreeformTwiceBuildsMainPlusTwo() {
    // 1|2/3 by splitting rather than by picking a preset — which is the whole
    // argument for dropping the presets, so it is asserted against a literal
    // shape rather than against a built-in that no longer ships.
    var profile = TileProfile(name: "scratch", root: .slot)
    #expect(profile.capacity == 1)
    profile.split(at: 0, direction: .vertical)
    profile.split(at: 1, direction: .horizontal)
    #expect(profile.capacity == 3)
    #expect(profile.root == .split(
        direction: .vertical, ratio: 0.5,
        first: .slot,
        second: .split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot)))
}

@Test func freeformCannotBeClosedDownToNothing() {
    // What makes a one-slot starting point safe: there is always a way back.
    var profile = TileProfile(name: "scratch", root: .slot)
    profile.close(at: 0)
    #expect(profile.capacity == 1)
    #expect(profile.root == .slot)
}

@Test func everyBuiltInHasItsOwnIdentity() {
    let ids = Set(TileLayout.builtIns.map(\.id))
    #expect(ids.count == TileLayout.builtIns.count)
}

@Test func aLayoutRoundTripsThroughJSON() throws {
    let layout = TileLayout(name: "Wide", grid: TilesGrid(columns: 3, rows: 1))
    let data = try JSONEncoder().encode(layout)
    #expect(try JSONDecoder().decode(TileLayout.self, from: data) == layout)
}

@Test func aLayoutClampsAnAbsurdGrid() throws {
    let json = """
    {"id":"\(UUID().uuidString)","name":"huge","grid":{"columns":40,"rows":40}}
    """
    let decoded = try JSONDecoder().decode(TileLayout.self, from: Data(json.utf8))
    #expect(decoded.root.leafCount == 64)
}

@Test func anOlderLibraryWithoutLayoutsStillLoads() throws {
    // Written before layouts existed: the key is simply absent.
    let json = #"{"profiles":[]}"#
    let decoded = try JSONDecoder().decode(TileProfileFile.self, from: Data(json.utf8))
    #expect(decoded.layouts.isEmpty)
    #expect(decoded.profiles.isEmpty)
}

@Test func aLibraryRoundTripsItsLayouts() throws {
    var file = TileProfileFile()
    file.layouts = TileLayout.builtIns
    file.profiles = [TileProfile(name: "morning", grid: TilesGrid(columns: 2, rows: 2))]
    let data = try JSONEncoder().encode(file)
    #expect(try JSONDecoder().decode(TileProfileFile.self, from: data) == file)
}

// MARK: - Seeding

@Test func aNewBuiltInReachesAnExistingLibrary() {
    var file = TileProfileFile(layouts: [TileLayout(name: "Mine", root: .slot)],
                               seededLayoutNames: ["Mine"])
    #expect(file.seedMissingLayouts() == true)
    #expect(file.layouts.contains { $0.name == "Freeform" })
}

@Test func aDeletedBuiltInStaysDeleted() {
    var file = TileProfileFile(layouts: [], seededLayoutNames: TileLayout.builtIns.map(\.name))
    #expect(file.seedMissingLayouts() == false)
    #expect(file.layouts.isEmpty)
}

@Test func aLibraryFromBeforeSeedTrackingKeepsWhatItHas() throws {
    // No seededLayoutNames key: its current names count as already offered, so
    // nothing the user removed comes back.
    let json = #"{"profiles":[],"layouts":[{"id":"\#(UUID().uuidString)","name":"Mine","grid":{"columns":3,"rows":1}}]}"#
    var decoded = try JSONDecoder().decode(TileProfileFile.self, from: Data(json.utf8))
    #expect(decoded.seededLayoutNames == ["Mine"])
    #expect(decoded.seedMissingLayouts() == true)
    #expect(decoded.layouts.contains { $0.name == "Freeform" })
    // The user's own layout is untouched by seeding.
    #expect(decoded.layouts.contains { $0.name == "Mine" })
}

@Test func theRetiredFocusLayoutIsClearedFromAnExistingLibrary() {
    var file = TileProfileFile(
        layouts: [TileLayout(name: "Focus", grid: TilesGrid(columns: 1, rows: 1))],
        seededLayoutNames: ["Focus"])
    #expect(file.seedMissingLayouts() == true)
    #expect(!file.layouts.contains { $0.name == "Focus" })
}

@Test func freeformSurvivesTheFocusCleanupDespiteHavingOneLeaf() {
    // The regression this guards: the cleanup used to remove EVERY one-leaf
    // layout, which would delete Freeform on the load right after seeding it —
    // and the recorded seed name means it would never come back.
    var file = TileProfileFile(
        layouts: [TileLayout(name: "Focus", grid: TilesGrid(columns: 1, rows: 1))],
        seededLayoutNames: ["Focus"])
    _ = file.seedMissingLayouts()
    #expect(file.layouts.contains { $0.name == "Freeform" })

    // The second load is the one that used to lose it.
    #expect(file.seedMissingLayouts() == false)
    #expect(file.layouts.contains { $0.name == "Freeform" })
}

@Test func aDeletedFreeformStaysDeleted() {
    var file = TileProfileFile(layouts: [], seededLayoutNames: ["Freeform"])
    _ = file.seedMissingLayouts()
    #expect(!file.layouts.contains { $0.name == "Freeform" })
}

@Test func aRenamedOneSlotLayoutIsLeftAlone() {
    // Cleanup is by name, so a single-leaf layout the user made their own is
    // not swept up with the retired built-in.
    var file = TileProfileFile(layouts: [TileLayout(name: "Scratchpad", root: .slot)],
                               seededLayoutNames: TileLayout.builtIns.map(\.name))
    #expect(file.seedMissingLayouts() == false)
    #expect(file.layouts.map(\.name) == ["Scratchpad"])
}

@Test func theWithdrawnPresetsAreClearedFromAnExistingLibrary() {
    var file = TileProfileFile(
        layouts: TileLayout.retiredBuiltIns.map { TileLayout(name: $0.name, root: $0.root) },
        seededLayoutNames: TileLayout.retiredBuiltIns.map(\.name))
    #expect(file.seedMissingLayouts() == true)
    #expect(file.layouts.map(\.name) == ["Freeform"])
}

@Test func aPresetTheUserEditedSurvivesTheCleanup() {
    // Same NAME as a withdrawn built-in, different shape — so it is their
    // work, not ours, and removing it would be an irreversible deletion of
    // something they deliberately changed.
    let edited = TileLayout(name: "Quad", grid: TilesGrid(columns: 3, rows: 3))
    var file = TileProfileFile(layouts: [edited], seededLayoutNames: ["Quad"])
    _ = file.seedMissingLayouts()
    #expect(file.layouts.contains { $0.name == "Quad" && $0.root.leafCount == 9 })
}

@Test func aUserLayoutWithNoBuiltInNameIsNeverTouched() {
    let mine = TileLayout(name: "3x3", grid: TilesGrid(columns: 3, rows: 3))
    var file = TileProfileFile(layouts: [mine],
                               seededLayoutNames: ["3x3", "Freeform"])
    #expect(file.seedMissingLayouts() == false)
    #expect(file.layouts.map(\.name) == ["3x3"])
}
