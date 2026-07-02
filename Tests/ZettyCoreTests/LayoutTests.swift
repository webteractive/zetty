import Testing
import Foundation
@testable import ZettyCore

private func surface(_ n: Int) -> Surface {
    Surface(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!,
            workingDir: "/tmp")
}

@Test func singleLeafHasOneSurface() {
    let layout = Layout(root: .leaf(surface(1)))
    #expect(layout.surfaces.map(\.id) == [surface(1).id])
}

@Test func splitReplacesLeafWithBinarySplit() {
    var layout = Layout(root: .leaf(surface(1)))
    let ok = layout.split(surfaceID: surface(1).id, direction: .vertical, newSurface: surface(2))
    #expect(ok)
    #expect(layout.surfaces.map(\.id) == [surface(1).id, surface(2).id])
    guard case let .split(direction, ratio, first, second) = layout.root else {
        Issue.record("root should be a split"); return
    }
    #expect(direction == .vertical)
    #expect(ratio == 0.5)
    #expect(first == .leaf(surface(1)))
    #expect(second == .leaf(surface(2)))
}

@Test func splitUnknownSurfaceReturnsFalse() {
    var layout = Layout(root: .leaf(surface(1)))
    #expect(layout.split(surfaceID: surface(9).id, direction: .horizontal, newSurface: surface(2)) == false)
}

@Test func closeCollapsesParentToSibling() {
    var layout = Layout(root: .leaf(surface(1)))
    _ = layout.split(surfaceID: surface(1).id, direction: .horizontal, newSurface: surface(2))
    let ok = layout.close(surfaceID: surface(1).id)
    #expect(ok)
    #expect(layout.root == .leaf(surface(2)))
}

@Test func closingTheOnlySurfaceFails() {
    var layout = Layout(root: .leaf(surface(1)))
    #expect(layout.close(surfaceID: surface(1).id) == false)
    #expect(layout.root == .leaf(surface(1)))
}

@Test func splitTargetsNonRootLeafLeavingSiblingsIntact() {
    var layout = Layout(root: .leaf(surface(1)))
    _ = layout.split(surfaceID: surface(1).id, direction: .horizontal, newSurface: surface(2))
    // Now split surface(2); surface(1) must remain untouched.
    let ok = layout.split(surfaceID: surface(2).id, direction: .vertical, newSurface: surface(3))
    #expect(ok)
    #expect(layout.surfaces.map(\.id) == [surface(1).id, surface(2).id, surface(3).id])
    guard case let .split(_, _, first, second) = layout.root else {
        Issue.record("root should be a split"); return
    }
    #expect(first == .leaf(surface(1)))
    guard case .split = second else {
        Issue.record("second child should itself be a split"); return
    }
}

@Test func closeCollapsesNestedParentToSibling() {
    var layout = Layout(root: .leaf(surface(1)))
    _ = layout.split(surfaceID: surface(1).id, direction: .horizontal, newSurface: surface(2))
    _ = layout.split(surfaceID: surface(2).id, direction: .vertical, newSurface: surface(3))
    // Tree: split(leaf1, split(leaf2, leaf3)). Close surface(2) -> inner split collapses to leaf3.
    let ok = layout.close(surfaceID: surface(2).id)
    #expect(ok)
    #expect(layout.surfaces.map(\.id) == [surface(1).id, surface(3).id])
    guard case let .split(_, _, first, second) = layout.root else {
        Issue.record("root should still be a split"); return
    }
    #expect(first == .leaf(surface(1)))
    #expect(second == .leaf(surface(3)))
}

@Test func setRatioClampsAndTargetsParentSplit() {
    var layout = Layout(root: .leaf(surface(1)))
    _ = layout.split(surfaceID: surface(1).id, direction: .horizontal, newSurface: surface(2))
    // Over-large ratio clamps to 0.95.
    let ok = layout.setRatio(parentOf: surface(1).id, to: 5.0)
    #expect(ok)
    guard case let .split(_, ratio, _, _) = layout.root else {
        Issue.record("root should be a split"); return
    }
    #expect(ratio == 0.95)
    // Unknown surface returns false.
    #expect(layout.setRatio(parentOf: surface(9).id, to: 0.5) == false)
}
