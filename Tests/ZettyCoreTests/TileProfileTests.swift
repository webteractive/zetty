import Foundation
import Testing
@testable import ZettyCore

private func slot(_ name: String) -> TileSlot {
    TileSlot(projectRoot: "/tmp/\(name)", tabID: UUID(), label: "\(name) / main")
}

private func profile(grid: TilesGrid = TilesGrid(columns: 2, rows: 2)) -> TileProfile {
    TileProfile(name: "morning", root: TileNode.uniform(grid))
}

@Test func aNewProfileHasAHoleForEveryCell() {
    let p = profile()
    #expect(p.capacity == 4)
    #expect(p.attachmentCount == 0)
    #expect(p.slots.count == 4)
}

@Test func attachingFillsThatSlotOnly() {
    var p = profile()
    let a = slot("zetty")
    p.attach(a, at: 2)
    #expect(p.slots[2] == a)
    #expect(p.slots[0] == nil)
    #expect(p.attachmentCount == 1)
}

@Test func attachingPastTheEndGrowsTheSlotList() {
    // The grid caps what is VISIBLE, not what can be attached.
    var p = profile()
    p.attach(slot("zetty"), at: 7)
    #expect(p.slots.count == 8)
    #expect(p.slots[7] != nil)
    #expect(p.attachmentCount == 1)
}

@Test func detachingLeavesAHoleRatherThanCompacting() {
    var p = profile()
    p.attach(slot("a"), at: 0)
    p.attach(slot("b"), at: 1)
    p.detach(at: 0)
    #expect(p.slots[0] == nil)
    #expect(p.slots[1] != nil)
}

@Test func splittingKeepsAttachmentsWithTheirLeaves() {
    // THE load-bearing invariant of the tree model: split an EARLIER slot and
    // the pane in a later one must still be in that same leaf.
    var p = profile(grid: TilesGrid(columns: 2, rows: 1))
    let pane = slot("zetty")
    p.attach(pane, at: 1)
    p.split(at: 0, direction: .horizontal)
    #expect(p.capacity == 3)
    #expect(p.slots[1] == nil)     // the new, empty leaf
    #expect(p.slots[2] == pane)    // shifted along with its leaf
}

@Test func closingASlotRemovesItsEntry() {
    var p = profile(grid: TilesGrid(columns: 2, rows: 1))
    let pane = slot("zetty")
    p.attach(pane, at: 1)
    p.close(at: 0)
    #expect(p.capacity == 1)
    #expect(p.slots == [pane])
}

@Test func closingTheLastSlotIsRefused() {
    var p = TileProfile(name: "m", root: .slot)
    p.close(at: 0)
    #expect(p.capacity == 1)
}

@Test func aProfileRoundTripsThroughJSON() throws {
    var p = profile()
    p.attach(slot("zetty"), at: 1)
    let data = try JSONEncoder().encode(p)
    #expect(try JSONDecoder().decode(TileProfile.self, from: data) == p)
}

@Test func anUnknownKindDecodesAsManualRatherThanThrowing() throws {
    // Profiles used to carry a `kind`; the computed view is gone and the key
    // is simply not read any more.
    let json = """
    {"id":"\(UUID().uuidString)","name":"x","kind":"allRunning",
     "grid":{"columns":2,"rows":2},"slots":[]}
    """
    let decoded = try JSONDecoder().decode(TileProfile.self, from: Data(json.utf8))
    #expect(decoded.name == "x")
    #expect(decoded.capacity == 4)
}

@Test func aHandEditedGridIsClampedOnDecode() throws {
    let json = """
    {"id":"\(UUID().uuidString)","name":"x","grid":{"columns":99,"rows":99},"slots":[]}
    """
    let decoded = try JSONDecoder().decode(TileProfile.self, from: Data(json.utf8))
    #expect(decoded.capacity == 64)
}

@Test func anOldProfileWithAGridDecodesToAUniformTree() throws {
    // Written before layouts were trees.
    let json = """
    {"id":"\(UUID().uuidString)","name":"m","grid":{"columns":2,"rows":3},"slots":[]}
    """
    let decoded = try JSONDecoder().decode(TileProfile.self, from: Data(json.utf8))
    #expect(decoded.root == TileNode.uniform(columns: 2, rows: 3))
    #expect(decoded.capacity == 6)
}

@Test func aMigratedProfileIsSavedAsATree() throws {
    // The legacy key is read once and never written back.
    let json = """
    {"id":"\(UUID().uuidString)","name":"m","grid":{"columns":2,"rows":2},"slots":[]}
    """
    let decoded = try JSONDecoder().decode(TileProfile.self, from: Data(json.utf8))
    let text = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
    #expect(text.contains("root"))
    #expect(!text.contains("grid"))
}
