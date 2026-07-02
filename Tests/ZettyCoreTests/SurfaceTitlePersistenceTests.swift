import Testing
import Foundation
@testable import ZettyCore

@Test func layoutUpdateMutatesTargetLeafOnly() {
    let a = Surface(workingDir: "/x")
    let b = Surface(workingDir: "/y")
    var layout = Layout(root: .split(direction: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)))

    #expect(layout.update(surfaceID: b.id) { $0.lastTitle = "claude" })
    #expect(layout.surfaces.first(where: { $0.id == b.id })?.lastTitle == "claude")
    #expect(layout.surfaces.first(where: { $0.id == a.id })?.lastTitle == nil)

    // Unknown surface → no change, returns false.
    #expect(layout.update(surfaceID: UUID()) { $0.lastTitle = "nope" } == false)
}

@Test func tabListUpdateSurfaceFindsTheOwningTree() {
    let list = TabList(defaultWorkingDir: "/x")
    list.newTab()
    let target = list.trees[1].layout.surfaces[0].id
    #expect(list.updateSurface(target) { $0.lastTitle = "hermes" })
    #expect(list.trees[1].layout.surfaces[0].lastTitle == "hermes")
    #expect(list.trees[0].layout.surfaces[0].lastTitle == nil)
    #expect(list.updateSurface(UUID()) { _ in } == false)
}

@Test func surfaceLastTitleRoundTripsThroughCodable() throws {
    var surface = Surface(workingDir: "/x")
    surface.lastTitle = "codex"
    let data = try JSONEncoder().encode(surface)
    let decoded = try JSONDecoder().decode(Surface.self, from: data)
    #expect(decoded.lastTitle == "codex")
}

@Test func surfaceDecodesLegacyJSONWithoutLastTitle() throws {
    // Pre-lastTitle workspace.json payloads must keep decoding.
    let legacy = #"{"id":"ABCDEF01-2345-6789-ABCD-EF0123456789","workingDir":"/x"}"#
    let decoded = try JSONDecoder().decode(Surface.self, from: Data(legacy.utf8))
    #expect(decoded.lastTitle == nil)
    #expect(decoded.workingDir == "/x")
}
