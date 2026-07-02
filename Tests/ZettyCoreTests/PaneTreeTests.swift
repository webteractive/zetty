// Tests/ZettyCoreTests/PaneTreeTests.swift
import Testing
import Foundation
@testable import ZettyCore

private func surface(_ n: Int) -> Surface {
    Surface(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!, workingDir: "/tmp")
}

@Test func newTreeFocusesItsOnlyLeaf() {
    let tree = PaneTree(layout: Layout(root: .leaf(surface(1))), focusedSurfaceID: surface(1).id)
    #expect(tree.focusedSurface?.id == surface(1).id)
}

@Test func splitFocusedMovesFocusToNewSurface() {
    var tree = PaneTree(layout: Layout(root: .leaf(surface(1))), focusedSurfaceID: surface(1).id)
    let ok = tree.splitFocused(direction: .vertical, newSurface: surface(2))
    #expect(ok)
    #expect(tree.layout.surfaces.map(\.id) == [surface(1).id, surface(2).id])
    #expect(tree.focusedSurfaceID == surface(2).id)
}

@Test func splitWithNoFocusReturnsFalse() {
    var tree = PaneTree(layout: Layout(root: .leaf(surface(1))), focusedSurfaceID: nil)
    #expect(tree.splitFocused(direction: .horizontal, newSurface: surface(2)) == false)
}

@Test func closeFocusedRefocusesARemainingSurface() {
    var tree = PaneTree(layout: Layout(root: .leaf(surface(1))), focusedSurfaceID: surface(1).id)
    _ = tree.splitFocused(direction: .horizontal, newSurface: surface(2)) // focus now surface(2)
    let ok = tree.closeFocused() // closes surface(2)
    #expect(ok)
    #expect(tree.layout.surfaces.map(\.id) == [surface(1).id])
    #expect(tree.focusedSurfaceID == surface(1).id)
}

@Test func closingOnlySurfaceFailsAndKeepsFocus() {
    var tree = PaneTree(layout: Layout(root: .leaf(surface(1))), focusedSurfaceID: surface(1).id)
    #expect(tree.closeFocused() == false)
    #expect(tree.focusedSurfaceID == surface(1).id)
}

@Test func focusIgnoresUnknownID() {
    var tree = PaneTree(layout: Layout(root: .leaf(surface(1))), focusedSurfaceID: surface(1).id)
    tree.focus(surface(9).id)
    #expect(tree.focusedSurfaceID == surface(1).id)
}
