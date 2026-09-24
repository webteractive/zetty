import Foundation
import Testing
@testable import ZettyCore

// Named layouts are gone: every preset was reachable by splitting one slot,
// and once a tile could be split and removed from its own face there was
// nothing left for a saved shape to save. What remains worth pinning is that a
// view still STARTS as one slot, still grows into the shapes the presets used
// to name, and that a library written when layouts existed still loads.

@Test func aViewStartsAsASingleSlot() {
    let profile = TileProfile(name: "scratch", root: .slot)
    #expect(profile.capacity == 1)
    #expect(profile.root == .slot)
}

@Test func splittingTwiceReachesMainPlusTwo() {
    // 1|2/3 by splitting — the shape the withdrawn "Main + Two" preset named,
    // and the reason it was withdrawn.
    var profile = TileProfile(name: "scratch", root: .slot)
    profile.split(at: 0, direction: .vertical)
    profile.split(at: 1, direction: .horizontal)
    #expect(profile.capacity == 3)
    #expect(profile.root == .split(
        direction: .vertical, ratio: 0.5,
        first: .slot,
        second: .split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot)))
}

@Test func aSingleSlotViewCannotBeClosedDownToNothing() {
    var profile = TileProfile(name: "scratch", root: .slot)
    profile.close(at: 0)
    #expect(profile.capacity == 1)
    #expect(profile.root == .slot)
}

@Test func aLibraryRoundTripsItsProfiles() throws {
    var file = TileProfileFile()
    file.profiles = [TileProfile(name: "morning", grid: TilesGrid(columns: 2, rows: 2))]
    let data = try JSONEncoder().encode(file)
    #expect(try JSONDecoder().decode(TileProfileFile.self, from: data) == file)
}

@Test func anOlderLibraryWithoutProfilesStillLoads() throws {
    let json = #"{}"#
    let decoded = try JSONDecoder().decode(TileProfileFile.self, from: Data(json.utf8))
    #expect(decoded.profiles.isEmpty)
}

@Test func aLibraryStillHoldingLayoutsLoadsAndDropsThem() throws {
    // Written while named layouts existed. The keys are simply not read, and
    // the next save drops them — the same one-way conversion the legacy `grid`
    // key gets. A profile in the same file must survive that untouched.
    let json = #"""
    {"profiles":[{"id":"\#(UUID().uuidString)","name":"kept","grid":{"columns":2,"rows":1},"slots":[]}],
     "layouts":[{"id":"\#(UUID().uuidString)","name":"Quad","grid":{"columns":2,"rows":2}}],
     "seededLayoutNames":["Quad","Freeform"]}
    """#
    let decoded = try JSONDecoder().decode(TileProfileFile.self, from: Data(json.utf8))
    #expect(decoded.profiles.map(\.name) == ["kept"])
    #expect(decoded.profiles.first?.capacity == 2)

    let round = try JSONEncoder().encode(decoded)
    let text = String(decoding: round, as: UTF8.self)
    #expect(!text.contains("layouts"))
    #expect(!text.contains("seededLayoutNames"))
}
