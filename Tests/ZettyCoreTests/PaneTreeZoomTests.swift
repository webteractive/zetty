import Foundation
import Testing
@testable import ZettyCore

private func surface(_ n: Int) -> Surface {
    Surface(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!,
            workingDir: "/tmp")
}

private func twoPaneTree() -> PaneTree {
    PaneTree(
        layout: Layout(root: .split(direction: .vertical, ratio: 0.5,
                                    first: .leaf(surface(1)), second: .leaf(surface(2)))),
        focusedSurfaceID: surface(1).id
    )
}

@Test func zoomTogglesOnFocusedPane() {
    var tree = twoPaneTree()
    let zoomed = tree.toggleZoom()
    #expect(zoomed)
    #expect(tree.zoomedSurfaceID == surface(1).id)
    let unzoomed = tree.toggleZoom()
    #expect(unzoomed)
    #expect(tree.zoomedSurfaceID == nil)
}

@Test func zoomFollowsCurrentFocusWhenReToggled() {
    var tree = twoPaneTree()
    _ = tree.toggleZoom()
    tree.focus(surface(2).id)
    // Toggling while a different pane is focused re-zooms onto it.
    let rezoomed = tree.toggleZoom()
    #expect(rezoomed)
    #expect(tree.zoomedSurfaceID == surface(2).id)
}

@Test func zoomFalseForSinglePane() {
    var tree = PaneTree(layout: Layout(root: .leaf(surface(1))), focusedSurfaceID: surface(1).id)
    let zoomed = tree.toggleZoom()
    #expect(!zoomed)
    #expect(tree.zoomedSurfaceID == nil)
}

@Test func splitWhileZoomedUnzooms() {
    var tree = twoPaneTree()
    _ = tree.toggleZoom()
    let split = tree.splitFocused(direction: .horizontal, newSurface: surface(3))
    #expect(split)
    #expect(tree.zoomedSurfaceID == nil)
}

@Test func closingZoomedPaneUnzooms() {
    var tree = twoPaneTree()
    _ = tree.toggleZoom()
    let closed = tree.closeFocused()
    #expect(closed)
    #expect(tree.zoomedSurfaceID == nil)
}

@Test func zoomIsTransientAcrossCodableRoundTrip() throws {
    var tree = twoPaneTree()
    _ = tree.toggleZoom()
    let data = try JSONEncoder().encode(tree)
    let decoded = try JSONDecoder().decode(PaneTree.self, from: data)
    #expect(decoded.zoomedSurfaceID == nil)
    #expect(decoded.layout == tree.layout)
    #expect(decoded.focusedSurfaceID == tree.focusedSurfaceID)
}
