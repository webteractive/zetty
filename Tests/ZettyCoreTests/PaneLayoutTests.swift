import Foundation
import Testing
@testable import ZettyCore

private let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
private let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
private let c = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!

private func leaf(_ id: UUID) -> SurfaceNode { .leaf(Surface(id: id, workingDir: "/tmp")) }

private let tree = SurfaceNode.split(direction: .vertical, ratio: 0.3, first: leaf(a),
                                     second: .split(direction: .horizontal, ratio: 0.5, first: leaf(b), second: leaf(c)))

private let expected = PaneLayout.split(direction: .vertical, ratio: 0.3, first: .pane("aaaaaaaa"),
                                        second: .split(direction: .horizontal, ratio: 0.5,
                                                       first: .pane("bbbbbbbb"), second: .pane("cccccccc")))

@Test func layoutMirrorsTheSplitTree() {
    let layout = PaneLayout(tree)
    #expect(layout == expected)
    #expect(layout.paneIDs == ["aaaaaaaa", "bbbbbbbb", "cccccccc"])
}

@Test func tabWithoutLayoutStillDecodes() throws {
    let json = #"{"title":"t","isActive":true,"panes":[]}"#
    let tab = try JSONDecoder().decode(StatusSnapshot.Tab.self, from: Data(json.utf8))
    #expect(tab.layout == nil)
    #expect(tab.title == "t")
}

@Test func layoutRoundTrips() throws {
    let tab = StatusSnapshot.Tab(title: "t", isActive: false, panes: [], layout: expected)
    let back = try JSONDecoder().decode(StatusSnapshot.Tab.self, from: JSONEncoder().encode(tab))
    #expect(back == tab)
    #expect(back.layout == expected)
}
