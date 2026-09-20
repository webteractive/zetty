import Foundation
import Testing
@testable import ZettyCore

private let unit = LayoutRect(x: 0, y: 0, width: 1, height: 1)

@Test func aLoneSlotFillsTheRect() {
    #expect(TileNode.slot.frames(in: unit) == [unit])
    #expect(TileNode.slot.leafCount == 1)
}

@Test func aVerticalSplitMakesTwoColumns() {
    let node = TileNode.split(direction: .vertical, ratio: 0.5, first: .slot, second: .slot)
    let frames = node.frames(in: unit)
    #expect(frames.count == 2)
    #expect(frames[0] == LayoutRect(x: 0, y: 0, width: 0.5, height: 1))
    #expect(frames[1] == LayoutRect(x: 0.5, y: 0, width: 0.5, height: 1))
}

@Test func aHorizontalSplitMakesTwoRows() {
    let node = TileNode.split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot)
    let frames = node.frames(in: unit)
    #expect(frames[0] == LayoutRect(x: 0, y: 0, width: 1, height: 0.5))
    #expect(frames[1] == LayoutRect(x: 0, y: 0.5, width: 1, height: 0.5))
}

@Test func theRatioIsHonoured() {
    let node = TileNode.split(direction: .vertical, ratio: 0.25, first: .slot, second: .slot)
    let frames = node.frames(in: unit)
    #expect(frames[0].width == 0.25)
    #expect(frames[1].x == 0.25)
    #expect(frames[1].width == 0.75)
}

@Test func oneBarTwoOverThree() {
    // 1|2/3 — two columns, the second divided.
    let node = TileNode.split(
        direction: .vertical, ratio: 0.5,
        first: .slot,
        second: .split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot))
    let frames = node.frames(in: unit)
    #expect(frames.count == 3)
    #expect(frames[0] == LayoutRect(x: 0, y: 0, width: 0.5, height: 1))
    #expect(frames[1] == LayoutRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    #expect(frames[2] == LayoutRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    #expect(node.leafCount == 3)
    #expect(node.depth == 2)
}

@Test func aUniformGridHasOneLeafPerCell() {
    let node = TileNode.uniform(columns: 3, rows: 2)
    #expect(node.leafCount == 6)
    let frames = node.frames(in: unit)
    // Row-major: the first three share a row.
    #expect(frames[0].y == frames[1].y)
    #expect(frames[0].x < frames[1].x)
    #expect(frames[3].y > frames[0].y)
}

@Test func aUniformGridDividesTheRectEvenly() {
    let frames = TileNode.uniform(columns: 2, rows: 2).frames(in: unit)
    #expect(frames.allSatisfy { abs($0.width - 0.5) < 1e-9 })
    #expect(frames.allSatisfy { abs($0.height - 0.5) < 1e-9 })
}

@Test func aThreeColumnGridIsEvenlyDivided() {
    // The chained-split construction must not produce 1/2, 1/4, 1/4.
    let frames = TileNode.uniform(columns: 3, rows: 1).frames(in: unit)
    #expect(frames.allSatisfy { abs($0.width - 1.0 / 3.0) < 1e-9 })
}

@Test func aNodeRoundTripsThroughJSON() throws {
    let node = TileNode.uniform(columns: 2, rows: 3)
    let data = try JSONEncoder().encode(node)
    #expect(try JSONDecoder().decode(TileNode.self, from: data) == node)
}

// MARK: - Dividers

@Test func everySplitReportsItsDivider() {
    let node = TileNode.split(
        direction: .vertical, ratio: 0.5,
        first: .slot,
        second: .split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot))
    let dividers = node.dividers(in: unit)
    #expect(dividers.count == 2)
    #expect(dividers[0].direction == .vertical)
    #expect(dividers[0].rect == unit)
    #expect(dividers[1].direction == .horizontal)
    #expect(dividers[1].rect == LayoutRect(x: 0.5, y: 0, width: 0.5, height: 1))
}

@Test func aDividersRatioCanBeSetByItsIndex() {
    var node = TileNode.uniform(columns: 2, rows: 1)
    #expect(node.setRatio(atDivider: 0, to: 0.3) == true)
    #expect(node.frames(in: unit)[0].width == 0.3)
}

@Test func aRatioIsClampedAwayFromTheEdges() {
    var node = TileNode.uniform(columns: 2, rows: 1)
    _ = node.setRatio(atDivider: 0, to: 0)
    #expect(node.frames(in: unit)[0].width > 0)
}

@Test func anUnknownDividerIsRefused() {
    var node = TileNode.slot
    #expect(node.setRatio(atDivider: 0, to: 0.3) == false)
}
