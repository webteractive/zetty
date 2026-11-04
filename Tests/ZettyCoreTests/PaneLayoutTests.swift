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

// MARK: - Rebuilding a remote tab (phase 2)

private func pane(_ id: String, cwd: String? = "/srv") -> StatusSnapshot.Pane {
    StatusSnapshot.Pane(id: id, title: nil, cwd: cwd, tool: nil, agentStatus: nil, isFocused: false, live: true)
}

private func shape(_ node: SurfaceNode) -> PaneLayout {
    switch node {
    case .leaf(let s): return .pane(s.id.uuidString)
    case .split(let d, let r, let a, let b): return .split(direction: d, ratio: r, first: shape(a), second: shape(b))
    }
}

@Test func remoteTabFollowsItsLayout() throws {
    var ids = RemoteSurfaceIDs()
    let tab = StatusSnapshot.Tab(title: "t", isActive: true,
                                 panes: [pane("aaaaaaaa"), pane("bbbbbbbb"), pane("cccccccc")], layout: expected)
    let node = try #require(PaneLayout.surfaceTree(for: tab, ids: &ids, machine: "mini"))
    let a = ids.id(machine: "mini", pane: "aaaaaaaa").uuidString
    let b = ids.id(machine: "mini", pane: "bbbbbbbb").uuidString
    let c = ids.id(machine: "mini", pane: "cccccccc").uuidString
    #expect(shape(node) == .split(direction: .vertical, ratio: 0.3, first: .pane(a),
                                  second: .split(direction: .horizontal, ratio: 0.5, first: .pane(b), second: .pane(c))))
    // The peer's directory is only a label: a relay never starts where it says.
    #expect(node.surfaces.map(\.workingDir) == ["/", "/", "/"])
}

@Test func remoteTabWithoutLayoutLaysPanesInARow() throws {
    var ids = RemoteSurfaceIDs()
    let tab = StatusSnapshot.Tab(title: "t", isActive: true, panes: [pane("a1"), pane("b2"), pane("c3", cwd: nil)])
    let node = try #require(PaneLayout.surfaceTree(for: tab, ids: &ids, machine: "mini"))
    #expect(node.surfaces.map(\.id) == ["a1", "b2", "c3"].map { ids.id(machine: "mini", pane: $0) })
    #expect(node.surfaces.last?.workingDir == "/")
    guard case .split(let direction, _, _, _) = node else { Issue.record("not a split"); return }
    #expect(direction == .vertical)
}

@Test func layoutNamingAMissingPaneFallsBackToARow() throws {
    var ids = RemoteSurfaceIDs()
    let tab = StatusSnapshot.Tab(title: "t", isActive: true, panes: [pane("aaaaaaaa"), pane("bbbbbbbb")],
                                 layout: expected) // names cccccccc, which isn't in panes
    let node = try #require(PaneLayout.surfaceTree(for: tab, ids: &ids, machine: "mini"))
    #expect(node.surfaces.count == 2)
}

@Test func emptyTabHasNoTree() {
    var ids = RemoteSurfaceIDs()
    #expect(PaneLayout.surfaceTree(for: StatusSnapshot.Tab(title: "t", isActive: true, panes: []),
                                   ids: &ids, machine: "mini") == nil)
}

@Test func remoteSurfaceIDsAreStableAndFresh() {
    var ids = RemoteSurfaceIDs()
    let first = ids.id(machine: "mini", pane: "aaaaaaaa")
    #expect(ids.id(machine: "mini", pane: "aaaaaaaa") == first)
    #expect(ids.id(machine: "studio", pane: "aaaaaaaa") != first)
    #expect(SessionPersistence.shortID(for: first) != "aaaaaaaa")
}

@Test func remoteTabDropsBadAndDuplicatePaneIDs() throws {
    var ids = RemoteSurfaceIDs()
    let tab = StatusSnapshot.Tab(title: "t", isActive: true,
                                 panes: [pane("aaaaaaaa"), pane("ab;rm -rf"), pane("aaaaaaaa"), pane("bbbbbbbb")])
    let node = try #require(PaneLayout.surfaceTree(for: tab, ids: &ids, machine: "mini"))
    #expect(node.surfaces.map(\.id) == ["aaaaaaaa", "bbbbbbbb"].map { ids.id(machine: "mini", pane: $0) })
}

@Test func remoteTabWithOnlyBadPaneIDsHasNoTree() {
    var ids = RemoteSurfaceIDs()
    let tab = StatusSnapshot.Tab(title: "t", isActive: true, panes: [pane("$(x)"), pane("")])
    #expect(PaneLayout.surfaceTree(for: tab, ids: &ids, machine: "mini") == nil)
}

@Test func remoteTabIsCappedAtMaxPanes() throws {
    var ids = RemoteSurfaceIDs()
    let many = (0..<5_000).map { pane(String(format: "%08x", $0)) }
    let node = try #require(PaneLayout.surfaceTree(for: StatusSnapshot.Tab(title: "t", isActive: true, panes: many),
                                                   ids: &ids, machine: "mini"))
    #expect(node.surfaces.count == PaneLayout.maxRemotePanes)
    #expect(PaneLayout.maxRemotePanes == 16)
}

@Test func remoteRatiosAreClampedToAUsableRange() throws {
    func ratio(_ r: Double) throws -> Double {
        var ids = RemoteSurfaceIDs()
        let layout = PaneLayout.split(direction: .vertical, ratio: r, first: .pane("aaaaaaaa"), second: .pane("bbbbbbbb"))
        let tab = StatusSnapshot.Tab(title: "t", isActive: true, panes: [pane("aaaaaaaa"), pane("bbbbbbbb")], layout: layout)
        guard case .split(_, let got, _, _) = try #require(PaneLayout.surfaceTree(for: tab, ids: &ids, machine: "mini"))
        else { Issue.record("not a split"); return .nan }
        return got
    }
    #expect(try ratio(0.3) == 0.3)
    #expect(try ratio(0) == 0.05)
    #expect(try ratio(7) == 0.95)
    #expect(try ratio(.nan) == 0.5)
    #expect(try ratio(-.infinity) == 0.5)
}
