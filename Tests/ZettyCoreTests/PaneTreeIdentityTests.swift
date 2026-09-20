import Foundation
import Testing
@testable import ZettyCore

@Test func aPaneTreeGetsAnIdentityOfItsOwn() {
    let a = PaneTree(layout: Layout(root: .leaf(Surface(workingDir: "/tmp"))))
    let b = PaneTree(layout: Layout(root: .leaf(Surface(workingDir: "/tmp"))))
    #expect(a.id != b.id)
}

@Test func aPaneTreeIdSurvivesARoundTrip() throws {
    let tree = PaneTree(layout: Layout(root: .leaf(Surface(workingDir: "/tmp"))))
    let data = try JSONEncoder().encode(tree)
    let decoded = try JSONDecoder().decode(PaneTree.self, from: data)
    #expect(decoded.id == tree.id)
}

@Test func anOlderWorkspaceWithoutAnIdStillLoads() throws {
    // A pre-existing workspace.json has no `id` on its trees. It must decode
    // and mint one rather than throwing — the same tolerance `isHome` and
    // `cloneSource` use.
    let original = PaneTree(layout: Layout(root: .leaf(Surface(workingDir: "/tmp"))))
    var object = try JSONSerialization.jsonObject(
        with: try JSONEncoder().encode(original)) as! [String: Any]
    object.removeValue(forKey: "id")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(PaneTree.self, from: stripped)
    #expect(decoded.layout.surfaces.count == 1)
}

@Test func renamingATabDoesNotChangeItsIdentity() {
    var tree = PaneTree(layout: Layout(root: .leaf(Surface(workingDir: "/tmp"))))
    let before = tree.id
    tree.manualTitle = "renamed"
    #expect(tree.id == before)
}

// MARK: - Identity across persistence

@Test func aTabIdentitySurvivesASaveAndRestore() {
    // The whole durability promise of a tile slot: it names a tab by id, so
    // that id must be the SAME object after a relaunch. `Tab` carries its own
    // `id` and `PaneTree` carries one too — if the snapshot does not thread
    // them together, every slot resolves as missing on the next launch.
    let surface = Surface(workingDir: "/tmp/zetty")
    let tree = PaneTree(layout: Layout(root: .leaf(surface)), focusedSurfaceID: surface.id)
    let original = tree.id

    let model = WorkspaceModel(restoring: [
        ProjectRuntime(name: "zetty", rootPath: "/tmp/zetty",
                       tabList: TabList(restoring: [tree], defaultWorkingDir: "/tmp/zetty")),
    ])!
    let saved = SessionSnapshot.workspace(from: model)
    let restored = SessionSnapshot.projectRuntimes(from: saved)

    #expect(restored.first?.tabList.trees.first?.id == original)
}
