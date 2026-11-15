import Foundation
import Testing
@testable import ZettyCore

@Test func roundTrips() throws {
    var surface = Surface(workingDir: "/spawn")
    surface.currentDirectory = "/tmp"
    let data = try JSONEncoder().encode(surface)
    #expect(try JSONDecoder().decode(Surface.self, from: data).currentDirectory == "/tmp")
}

@Test func decodesOlderWorkspaceWithoutKey() throws {
    let json = #"{"id":"00000000-0000-0000-0000-0000000000C1","workingDir":"/spawn"}"#
    let surface = try JSONDecoder().decode(Surface.self, from: Data(json.utf8))
    #expect(surface.currentDirectory == nil)
    #expect(surface.workingDir == "/spawn")
}
