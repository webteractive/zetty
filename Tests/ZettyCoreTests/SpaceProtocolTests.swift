import Testing
import Foundation
@testable import ZettyCore

private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(ControlRequest.self, from: data)
}

@Test func spaceRequestsRoundTrip() throws {
    let requests: [ControlRequest] = [
        .newSpace(name: "Client Acme", colorID: "teal", glyph: "briefcase.fill"),
        .newSpace(name: "Bare", colorID: nil, glyph: nil),
        .renameSpace(name: "Old", newName: "New"),
        .removeSpace(name: "Client Acme"),
        .moveToSpace(project: "acme-api", space: "Client Acme"),
        .moveToSpace(project: "acme-api", space: nil),
        .hibernateSpace(name: "Client Acme"),
        .wakeSpace(name: "Client Acme"),
        .addProject(path: "/tmp/x", name: nil, space: "Client Acme", focus: false),
    ]
    for request in requests {
        #expect(try roundTrip(request) == request)
    }
}

@Test func addProjectDecodesWithoutASpaceKey() throws {
    let json = #"{"command":"add-project","path":"/tmp/x"}"#
    let request = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
    #expect(request == .addProject(path: "/tmp/x", name: nil, space: nil, focus: false))
}

@Test func statusSnapshotDecodesWithoutSpacesFields() throws {
    let json = #"{"projects":[{"name":"solo","isActive":true,"tabs":[]}]}"#
    let snapshot = try JSONDecoder().decode(StatusSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.spaces.isEmpty)
    #expect(snapshot.projects.first?.space == nil)
}

@Test func statusSnapshotRoundTripsSpaces() throws {
    let snapshot = StatusSnapshot(
        projects: [.init(name: "acme-api", isActive: true, hibernated: false,
                         space: "Client Acme", tabs: [])],
        spaces: [.init(name: "Client Acme", collapsed: false),
                 .init(name: "Empty One", collapsed: true)]
    )
    let decoded = try JSONDecoder().decode(StatusSnapshot.self,
                                           from: try JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
}

@Test func spaceRequestsEncodeTheirExactWireCommands() throws {
    // Pins the literals themselves. A round-trip test can't: mistyping a
    // command on both the encode and decode side still round-trips green,
    // while the CLI and app — which match on these strings — break at runtime.
    let expected: [(ControlRequest, String)] = [
        (.newSpace(name: "S", colorID: nil, glyph: nil), "new-space"),
        (.renameSpace(name: "A", newName: "B"), "rename-space"),
        (.removeSpace(name: "S"), "remove-space"),
        (.moveToSpace(project: "p", space: nil), "move-to-space"),
        (.hibernateSpace(name: "S"), "hibernate-space"),
        (.wakeSpace(name: "S"), "wake-space"),
        (.addProject(path: "/tmp/x", name: nil, space: nil, focus: false), "add-project"),
    ]
    for (request, command) in expected {
        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(request)) as? [String: Any]
        #expect(object?["command"] as? String == command)
    }
}

@Test func spaceRequestFieldsUseTheirDocumentedWireKeys() throws {
    // Same reasoning one level down: the CODING KEY names are part of the
    // wire contract, and encode/decode symmetry hides a renamed key.
    let created = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(
        ControlRequest.newSpace(name: "S", colorID: "teal", glyph: "briefcase.fill"))) as? [String: Any]
    #expect(created?["name"] as? String == "S")
    #expect(created?["color"] as? String == "teal")
    #expect(created?["icon"] as? String == "briefcase.fill")

    let moved = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(
        ControlRequest.moveToSpace(project: "p", space: "S"))) as? [String: Any]
    #expect(moved?["project"] as? String == "p")
    #expect(moved?["space"] as? String == "S")

    let renamed = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(
        ControlRequest.renameSpace(name: "A", newName: "B"))) as? [String: Any]
    #expect(renamed?["newName"] as? String == "B")
}
