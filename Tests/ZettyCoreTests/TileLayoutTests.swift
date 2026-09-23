import Foundation
import Testing
@testable import ZettyCore

@Test func theBuiltInLayoutsCoverTheCommonShapes() {
    let names = TileLayout.builtIns.map(\.name)
    #expect(names == ["Freeform", "Pair", "Stack", "Quad", "Grid",
                      "Main + Two", "Two + Main"])
    #expect(TileLayout.builtIns.map(\.root.leafCount) == [1, 2, 2, 4, 16, 3, 3])
}

@Test func freeformIsTheOnlySingleSlotBuiltIn() {
    // Every other built-in commits you to a shape; this one is the canvas you
    // split into whatever the work turns out to need.
    let single = TileLayout.builtIns.filter { $0.root.leafCount == 1 }
    #expect(single.map(\.name) == ["Freeform"])
    #expect(single.first?.root == .slot)
}

@Test func splittingFreeformTwiceBuildsMainPlusTwo() {
    // The shape the request named — 1|2/3 — reached by splitting rather than
    // by picking a preset.
    var profile = TileProfile(name: "scratch", root: .slot)
    #expect(profile.capacity == 1)
    profile.split(at: 0, direction: .vertical)
    profile.split(at: 1, direction: .horizontal)
    #expect(profile.capacity == 3)
    #expect(profile.root == TileLayout.builtIns.first { $0.name == "Main + Two" }?.root)
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
    var file = TileProfileFile(layouts: [TileLayout(name: "Pair",
                                                    grid: TilesGrid(columns: 2, rows: 1))],
                               seededLayoutNames: ["Pair"])
    #expect(file.seedMissingLayouts() == true)
    #expect(file.layouts.contains { $0.name == "Main + Two" })
}

@Test func aDeletedBuiltInStaysDeleted() {
    var file = TileProfileFile(layouts: [], seededLayoutNames: TileLayout.builtIns.map(\.name))
    #expect(file.seedMissingLayouts() == false)
    #expect(file.layouts.isEmpty)
}

@Test func aLibraryFromBeforeSeedTrackingKeepsWhatItHas() throws {
    // No seededLayoutNames key: its current names count as already offered, so
    // nothing the user removed comes back.
    let json = #"{"profiles":[],"layouts":[{"id":"\#(UUID().uuidString)","name":"Pair","grid":{"columns":2,"rows":1}}]}"#
    var decoded = try JSONDecoder().decode(TileProfileFile.self, from: Data(json.utf8))
    #expect(decoded.seededLayoutNames == ["Pair"])
    #expect(decoded.seedMissingLayouts() == true)
    #expect(decoded.layouts.contains { $0.name == "Main + Two" })
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
