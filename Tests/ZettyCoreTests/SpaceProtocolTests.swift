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
