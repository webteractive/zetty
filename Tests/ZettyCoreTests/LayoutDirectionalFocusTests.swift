import Foundation
import Testing
@testable import ZettyCore

private func surface(_ n: Int) -> Surface {
    Surface(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!,
            workingDir: "/tmp")
}

/// [1 | 2] side by side.
private func twoColumns() -> Layout {
    Layout(root: .split(direction: .vertical, ratio: 0.5,
                        first: .leaf(surface(1)), second: .leaf(surface(2))))
}

/// 1 on top, 2 below.
private func twoRows() -> Layout {
    Layout(root: .split(direction: .horizontal, ratio: 0.5,
                        first: .leaf(surface(1)), second: .leaf(surface(2))))
}

/// L-shape: left column is 1, right column is 2 over 3.
///   [ 1 | 2 ]
///   [ 1 | 3 ]
private func lShape() -> Layout {
    Layout(root: .split(
        direction: .vertical, ratio: 0.5,
        first: .leaf(surface(1)),
        second: .split(direction: .horizontal, ratio: 0.5,
                       first: .leaf(surface(2)), second: .leaf(surface(3)))
    ))
}

// MARK: - frames(in:)

@Test func framesSingleLeafFillsUnit() {
    let layout = Layout(root: .leaf(surface(1)))
    let frames = layout.frames()
    #expect(frames[surface(1).id] == LayoutRect(x: 0, y: 0, width: 1, height: 1))
}

@Test func framesVerticalSplitCutsXAxis() {
    let frames = twoColumns().frames()
    #expect(frames[surface(1).id] == LayoutRect(x: 0, y: 0, width: 0.5, height: 1))
    #expect(frames[surface(2).id] == LayoutRect(x: 0.5, y: 0, width: 0.5, height: 1))
}

@Test func framesHorizontalSplitCutsYAxisTopFirst() {
    let frames = twoRows().frames()
    #expect(frames[surface(1).id] == LayoutRect(x: 0, y: 0, width: 1, height: 0.5))
    #expect(frames[surface(2).id] == LayoutRect(x: 0, y: 0.5, width: 1, height: 0.5))
}

@Test func framesRespectRatio() {
    let layout = Layout(root: .split(direction: .vertical, ratio: 0.25,
                                     first: .leaf(surface(1)), second: .leaf(surface(2))))
    let frames = layout.frames()
    #expect(frames[surface(1).id]!.width == 0.25)
    #expect(frames[surface(2).id]!.minX == 0.25)
}

// MARK: - neighbor(of:direction:)

@Test func neighborInTwoColumns() {
    let layout = twoColumns()
    #expect(layout.neighbor(of: surface(1).id, direction: .right) == surface(2).id)
    #expect(layout.neighbor(of: surface(2).id, direction: .left) == surface(1).id)
    // No wrap at the edges, and no vertical neighbors in a single row.
    #expect(layout.neighbor(of: surface(1).id, direction: .left) == nil)
    #expect(layout.neighbor(of: surface(2).id, direction: .right) == nil)
    #expect(layout.neighbor(of: surface(1).id, direction: .up) == nil)
    #expect(layout.neighbor(of: surface(1).id, direction: .down) == nil)
}

@Test func neighborInTwoRows() {
    let layout = twoRows()
    #expect(layout.neighbor(of: surface(1).id, direction: .down) == surface(2).id)
    #expect(layout.neighbor(of: surface(2).id, direction: .up) == surface(1).id)
    #expect(layout.neighbor(of: surface(1).id, direction: .up) == nil)
}

@Test func neighborInLShapePicksByOverlap() {
    let layout = lShape()
    // 1 fills the whole left column: going right, both 2 and 3 overlap it
    // equally — the tie-break picks the nearest (both at same distance), so
    // either is defensible; the implementation prefers the larger overlap
    // then the topmost/leftmost, which is 2.
    #expect(layout.neighbor(of: surface(1).id, direction: .right) == surface(2).id)
    // From 2 and 3, going left always lands on 1.
    #expect(layout.neighbor(of: surface(2).id, direction: .left) == surface(1).id)
    #expect(layout.neighbor(of: surface(3).id, direction: .left) == surface(1).id)
    // 2 and 3 are vertical neighbors.
    #expect(layout.neighbor(of: surface(2).id, direction: .down) == surface(3).id)
    #expect(layout.neighbor(of: surface(3).id, direction: .up) == surface(2).id)
    // 1 has no up/down neighbor (nothing beyond its own edges).
    #expect(layout.neighbor(of: surface(1).id, direction: .up) == nil)
    #expect(layout.neighbor(of: surface(1).id, direction: .down) == nil)
}

@Test func neighborOfUnknownSurfaceIsNil() {
    #expect(twoColumns().neighbor(of: UUID(), direction: .left) == nil)
}

// MARK: - PaneTree.focusNeighbor / cycleFocus

@Test func focusNeighborMovesFocus() {
    var tree = PaneTree(layout: twoColumns(), focusedSurfaceID: surface(1).id)
    let moved = tree.focusNeighbor(.right)
    #expect(moved)
    #expect(tree.focusedSurfaceID == surface(2).id)
    // At the right edge nothing changes and the call reports failure.
    let movedAgain = tree.focusNeighbor(.right)
    #expect(!movedAgain)
    #expect(tree.focusedSurfaceID == surface(2).id)
}

@Test func focusNeighborFalseForSinglePane() {
    var tree = PaneTree(layout: Layout(root: .leaf(surface(1))), focusedSurfaceID: surface(1).id)
    let moved = tree.focusNeighbor(.left)
    #expect(!moved)
}

@Test func cycleFocusWrapsInSurfaceOrder() {
    var tree = PaneTree(layout: lShape(), focusedSurfaceID: surface(1).id)
    for expected in [surface(2).id, surface(3).id, surface(1).id] {   // wraps at the end
        let cycled = tree.cycleFocus()
        #expect(cycled)
        #expect(tree.focusedSurfaceID == expected)
    }
}

@Test func cycleFocusFalseForSinglePane() {
    var tree = PaneTree(layout: Layout(root: .leaf(surface(1))), focusedSurfaceID: surface(1).id)
    let cycled = tree.cycleFocus()
    #expect(!cycled)
}
