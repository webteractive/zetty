import Foundation
import Testing
@testable import ZettyCore

// An older workspace.json has no runningAccountID key — it must still decode,
// the same tolerance lastTitle and accountID rely on.
@Test func surfaceDecodesWithoutRunningAccountID() throws {
    let json = #"{"id":"5F0C2A1E-0000-4000-8000-000000000001","workingDir":"/tmp"}"#
    let surface = try JSONDecoder().decode(Surface.self, from: Data(json.utf8))
    #expect(surface.runningAccountID == nil)
    #expect(surface.workingDir == "/tmp")
}

@Test func surfaceRoundTripsRunningAccountID() throws {
    var surface = Surface(workingDir: "/tmp", accountID: "work")
    surface.runningAccountID = "personal"
    let data = try JSONEncoder().encode(surface)
    let decoded = try JSONDecoder().decode(Surface.self, from: data)
    #expect(decoded.runningAccountID == "personal")
    // The spawn stamp is untouched — the override is a separate fact.
    #expect(decoded.accountID == "work")
}
