import Foundation
import Testing
@testable import ZettyCore

private func slot(_ name: String) -> TileSlot {
    TileSlot(projectRoot: "/tmp/\(name)", tabID: UUID(), label: "\(name) / main")
}

private func profile(grid: TilesGrid = TilesGrid(columns: 2, rows: 2)) -> TileProfile {
    TileProfile(name: "morning", grid: grid)
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

@Test func shrinkingTheGridNeverDropsAnAttachment() {
    // The invariant that makes grid-as-a-cap safe.
    var p = profile(grid: TilesGrid(columns: 4, rows: 4))
    for index in 0..<12 { p.attach(slot("p\(index)"), at: index) }
    p.setGrid(TilesGrid(columns: 1, rows: 1))
    #expect(p.attachmentCount == 12)
    #expect(p.slots.count == 12)
}

@Test func growingTheGridAddsHolesToAttachInto() {
    var p = profile(grid: TilesGrid(columns: 1, rows: 1))
    p.attach(slot("a"), at: 0)
    p.setGrid(TilesGrid(columns: 2, rows: 2))
    #expect(p.capacity == 4)
    #expect(p.slots.count == 4)
    #expect(p.attachmentCount == 1)
}

@Test func aProfileRoundTripsThroughJSON() throws {
    var p = profile()
    p.attach(slot("zetty"), at: 1)
    let data = try JSONEncoder().encode(p)
    #expect(try JSONDecoder().decode(TileProfile.self, from: data) == p)
}

@Test func anUnknownKindDecodesAsManualRatherThanThrowing() throws {
    // Forward compatibility: an older build must not choke on a newer file.
    let json = """
    {"id":"\(UUID().uuidString)","name":"x","kind":"someFutureKind",
     "grid":{"columns":2,"rows":2},"slots":[]}
    """
    let decoded = try JSONDecoder().decode(TileProfile.self, from: Data(json.utf8))
    #expect(decoded.kind == .manual)
}

@Test func aHandEditedGridIsClampedOnDecode() throws {
    let json = """
    {"id":"\(UUID().uuidString)","name":"x","kind":"manual",
     "grid":{"columns":99,"rows":99},"slots":[]}
    """
    let decoded = try JSONDecoder().decode(TileProfile.self, from: Data(json.utf8))
    #expect(decoded.grid == TilesGrid(columns: 8, rows: 8))
}
