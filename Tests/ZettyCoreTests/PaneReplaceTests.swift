import XCTest
@testable import ZettyCore

/// Moving a pane to a different account means a NEW surface in the same slot —
/// a pane's environment is captured when its surface is created, so reusing the
/// id would reattach the old session with the old environment.
final class PaneReplaceTests: XCTestCase {

    private func splitTree() -> (PaneTree, Surface, Surface) {
        let first = Surface(workingDir: "/a")
        var tree = PaneTree(layout: Layout(root: .leaf(first)), focusedSurfaceID: first.id)
        let second = Surface(workingDir: "/b")
        tree.splitFocused(direction: .vertical, newSurface: second, ratio: 0.3)
        return (tree, first, second)
    }

    func testKeepsSlotSiblingsAndRatio() {
        var (tree, first, second) = splitTree()
        guard case let .split(_, ratio, _, _) = tree.layout.root else {
            return XCTFail("expected a split")
        }

        let replacement = Surface(workingDir: "/a", accountID: "work")
        XCTAssertTrue(tree.replaceSurface(first.id, with: replacement))

        XCTAssertEqual(tree.layout.surfaces.count, 2)
        XCTAssertEqual(tree.layout.surfaces.map(\.id), [replacement.id, second.id])
        guard case let .split(_, newRatio, _, _) = tree.layout.root else {
            return XCTFail("split collapsed")
        }
        XCTAssertEqual(newRatio, ratio, "the divider must not move")
    }

    func testCarriesFocusToTheReplacement() {
        var (tree, _, second) = splitTree()
        XCTAssertEqual(tree.focusedSurfaceID, second.id)
        let replacement = Surface(workingDir: "/b", accountID: "personal")
        tree.replaceSurface(second.id, with: replacement)
        XCTAssertEqual(tree.focusedSurfaceID, replacement.id)
    }

    /// A zoom left pointing at a dead leaf makes the pane vanish.
    func testCarriesZoomToTheReplacement() {
        var (tree, _, second) = splitTree()
        tree.zoomedSurfaceID = second.id
        let replacement = Surface(workingDir: "/b")
        tree.replaceSurface(second.id, with: replacement)
        XCTAssertEqual(tree.zoomedSurfaceID, replacement.id)
        XCTAssertTrue(tree.layout.surfaces.contains { $0.id == tree.zoomedSurfaceID })
    }

    func testLeavesOtherPanesFocusAndZoomAlone() {
        var (tree, first, second) = splitTree()
        tree.zoomedSurfaceID = second.id
        tree.replaceSurface(first.id, with: Surface(workingDir: "/a"))
        XCTAssertEqual(tree.focusedSurfaceID, second.id)
        XCTAssertEqual(tree.zoomedSurfaceID, second.id)
    }

    func testReplacingTheOnlyPaneWorks() {
        let only = Surface(workingDir: "/a")
        var tree = PaneTree(layout: Layout(root: .leaf(only)), focusedSurfaceID: only.id)
        let replacement = Surface(workingDir: "/a", accountID: "work")
        XCTAssertTrue(tree.replaceSurface(only.id, with: replacement))
        XCTAssertEqual(tree.layout.surfaces.map(\.id), [replacement.id])
        XCTAssertEqual(tree.focusedSurfaceID, replacement.id)
    }

    func testUnknownSurfaceIsANoOp() {
        var (tree, _, _) = splitTree()
        let before = tree
        XCTAssertFalse(tree.replaceSurface(UUID(), with: Surface(workingDir: "/x")))
        XCTAssertEqual(tree, before)
    }
}
