import Foundation
import Testing
@testable import ZettyCore

private let box = LayoutRect(x: 0, y: 0, width: 1, height: 1)

@Test func splittingALeafAddsOneAfterIt() {
    var node = TileNode.uniform(columns: 2, rows: 1)   // leaves 0,1
    #expect(node.split(at: 0, direction: .horizontal) == true)
    #expect(node.leafCount == 3)
    // The two new leaves sit inside the FIRST column, so they share its x.
    let frames = node.frames(in: box)
    #expect(frames[0].x == 0)
    #expect(frames[1].x == 0)
    #expect(frames[2].x == 0.5)
}

@Test func splittingTheLastLeafAppends() {
    var node = TileNode.uniform(columns: 2, rows: 1)
    #expect(node.split(at: 1, direction: .horizontal) == true)
    #expect(node.leafCount == 3)
    let frames = node.frames(in: box)
    #expect(frames[1].x == 0.5)
    #expect(frames[2].x == 0.5)
}

@Test func splittingOutOfRangeIsRefused() {
    var node = TileNode.slot
    #expect(node.split(at: 4, direction: .vertical) == false)
    #expect(node.leafCount == 1)
}

@Test func splittingNestsWithoutLimit() {
    var node = TileNode.slot
    node.split(at: 0, direction: .vertical)
    node.split(at: 1, direction: .horizontal)
    node.split(at: 2, direction: .vertical)
    #expect(node.leafCount == 4)
    #expect(node.depth == 3)
}

@Test func closingCollapsesTheParentIntoTheSibling() {
    var node = TileNode.uniform(columns: 2, rows: 1)
    #expect(node.close(at: 1) == true)
    #expect(node == .slot)
}

@Test func closingTheOnlyLeafIsRefused() {
    // A view with no slots has nothing to show, and no way back.
    var node = TileNode.slot
    #expect(node.close(at: 0) == false)
    #expect(node.leafCount == 1)
}

@Test func closingKeepsTheRestOfTheTree() {
    // 1|2/3 -> close leaf 2 -> 1|2
    var node = TileNode.split(
        direction: .vertical, ratio: 0.5,
        first: .slot,
        second: .split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot))
    #expect(node.close(at: 2) == true)
    #expect(node.leafCount == 2)
    #expect(node == .split(direction: .vertical, ratio: 0.5, first: .slot, second: .slot))
}

@Test func settingOneDividerLeavesTheOthersAlone() {
    var node = TileNode.split(
        direction: .vertical, ratio: 0.5,
        first: .slot,
        second: .split(direction: .horizontal, ratio: 0.5, first: .slot, second: .slot))
    #expect(node.setRatio(atDivider: 1, to: 0.8) == true)
    let dividers = node.dividers(in: box)
    #expect(dividers[0].ratio == 0.5)
    #expect(dividers[1].ratio == 0.8)
}
