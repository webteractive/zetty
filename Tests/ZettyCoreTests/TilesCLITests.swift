import Foundation
import Testing
@testable import ZettyCore

// MARK: - Grammar

@Test func theOriginalToggleFormStillParses() {
    #expect(ControlCLI.parseTiles([]) == .request(.tiles(on: nil, profile: nil)))
    #expect(ControlCLI.parseTiles(["--off"]) == .request(.tiles(on: false, profile: nil)))
    #expect(ControlCLI.parseTiles(["--profile", "morning"])
        == .request(.tiles(on: nil, profile: "morning")))
    #expect(ControlCLI.parseTiles(["--nope"]) == .failure("unknown argument \"--nope\""))
}

@Test func libraryVerbsJoinMultiWordNames() {
    #expect(ControlCLI.parseTiles(["open", "Morning", "Review"])
        == .request(.tiles(on: true, profile: "Morning Review")))
    #expect(ControlCLI.parseTiles(["new"]) == .request(.tileNew(name: nil)))
    #expect(ControlCLI.parseTiles(["new", "Deep", "Work"]) == .request(.tileNew(name: "Deep Work")))
    #expect(ControlCLI.parseTiles(["delete", "Deep", "Work"]) == .request(.tileDelete(name: "Deep Work")))
    #expect(ControlCLI.parseTiles(["list", "--json"]) == .list(json: true))
}

@Test func renameTakesTwoWordsOrATo() {
    #expect(ControlCLI.parseTiles(["rename", "a", "b"])
        == .request(.tileRename(name: "a", newName: "b")))
    #expect(ControlCLI.parseTiles(["rename", "deep", "work", "--to", "focus", "time"])
        == .request(.tileRename(name: "deep work", newName: "focus time")))
    // Three bare words cannot be split unambiguously.
    if case .failure = ControlCLI.parseTiles(["rename", "a", "b", "c"]) {} else {
        Issue.record("expected a usage failure")
    }
    if case .failure = ControlCLI.parseTiles(["rename", "a"]) {} else {
        Issue.record("rename needs a new name")
    }
}

@Test func duplicateMayOmitTheNewName() {
    #expect(ControlCLI.parseTiles(["duplicate", "a"])
        == .request(.tileDuplicate(name: "a", newName: nil)))
    #expect(ControlCLI.parseTiles(["dup", "a", "b"])
        == .request(.tileDuplicate(name: "a", newName: "b")))
}

@Test func slotVerbsParseTheirFlags() {
    #expect(ControlCLI.parseTiles(["attach", "--pane", "ab12", "--slot", "3", "--view", "Morning"])
        == .request(.tileAttach(target: .pane("ab12"), slot: 3, view: "Morning")))
    #expect(ControlCLI.parseTiles(["attach"])
        == .request(.tileAttach(target: .focused, slot: nil, view: nil)))
    #expect(ControlCLI.parseTiles(["detach", "--slot", "2", "--collapse"])
        == .request(.tileDetach(slot: 2, collapse: true, view: nil)))
    #expect(ControlCLI.parseTiles(["split", "--horizontal"])
        == .request(.tileSplit(slot: nil, vertical: false, view: nil)))
}

@Test func slotVerbsRejectFlagsThatBelongToAnother() {
    // --collapse means nothing to split, --pane nothing to detach.
    #expect(ControlCLI.parseTiles(["split", "--collapse"]) == .failure("unknown argument \"--collapse\""))
    #expect(ControlCLI.parseTiles(["detach", "--pane", "ab"]) == .failure("unknown argument \"--pane\""))
}

@Test func slotNumbersStartAtOne() {
    #expect(ControlCLI.parseTiles(["split", "--slot", "0"])
        == .failure("--slot needs a slot number (1 or more)"))
    #expect(ControlCLI.parseTiles(["split", "--slot", "x"])
        == .failure("--slot needs a slot number (1 or more)"))
}

@Test func tilesHelpExitsZeroWithoutTheApp() {
    #expect(ControlCLI.run(["tiles", "attach", "--help"]) == 0)
    #expect(ControlCLI.run(["tiles", "bogus"]) == 1)
}

// MARK: - Wire

@Test func tileRequestsRoundTrip() throws {
    let requests: [ControlRequest] = [
        .tileNew(name: "Deep Work"), .tileNew(name: nil),
        .tileRename(name: "a", newName: "b"),
        .tileDelete(name: "a"),
        .tileDuplicate(name: "a", newName: nil),
        .tileAttach(target: .cwd("/tmp"), slot: 2, view: "v"),
        .tileDetach(slot: nil, collapse: true, view: nil),
        .tileSplit(slot: 1, vertical: false, view: nil),
    ]
    for request in requests {
        #expect(try ControlWire.decodeRequest(ControlWire.encodeLine(request)) == request)
    }
}

@Test func aStatusWithoutTilesStillDecodes() throws {
    // An older app sends no `tiles` key at all.
    let json = #"{"ok":true,"status":{"projects":[]}}"#
    guard case .status(let snapshot) = try ControlWire.decodeResponse(json) else {
        Issue.record("expected a status"); return
    }
    #expect(snapshot.tiles == nil)
}

@Test func tilesStatusRoundTrips() throws {
    let tiles = StatusSnapshot.Tiles(
        active: true, view: "Morning",
        slots: [.init(slot: 1, state: "pane", pane: "ab12cd34", label: "zetty / main", isFocused: true),
                .init(slot: 2, state: "empty")],
        views: [.init(name: "Morning", isOpen: true, isActive: true, slots: 2, attached: 1)])
    let response = ControlResponse.status(StatusSnapshot(projects: [], tiles: tiles))
    #expect(try ControlWire.decodeResponse(ControlWire.encodeLine(response)) == response)
}

// MARK: - Output

@Test func statusShowsTheGridOnlyWhileItIsUp() {
    let slots: [StatusSnapshot.Tiles.Slot] = [
        .init(slot: 1, state: "pane", pane: "ab12cd34", label: "zetty / main", isFocused: true),
        .init(slot: 2, state: "missing", label: "gone / tab"),
        .init(slot: 3, state: "empty"),
    ]
    let up = StatusSnapshot(projects: [], tiles: .init(active: true, view: "Morning", slots: slots, views: []))
    #expect(ControlCLI.statusLines(up) == [
        "▦ tiles  [Morning]",
        "  1  ab12cd34  zetty / main  *",
        "  2  (missing)  gone / tab",
        "  3  (empty)",
    ])
    let down = StatusSnapshot(projects: [], tiles: .init(active: false, view: "Morning", slots: slots, views: []))
    #expect(ControlCLI.statusLines(down).isEmpty)
}

@Test func tileListMarksShowingOpenAndClosedViews() {
    let tiles = StatusSnapshot.Tiles(active: true, view: "A", slots: [], views: [
        .init(name: "A", isOpen: true, isActive: true, slots: 4, attached: 3),
        .init(name: "B", isOpen: true, isActive: false, slots: 1, attached: 0),
        .init(name: "C", isOpen: false, isActive: false, slots: 2, attached: 2),
    ])
    #expect(ControlCLI.tileViewLines(tiles) == [
        "● A  3/4  (showing)",
        "○ B  0/1  (open)",
        "  C  2/2",
    ])
}
