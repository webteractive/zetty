import XCTest
@testable import ZettyCore

/// `accountID` must be optional on the wire: a `workspace.json` written by a
/// build without accounts has to keep loading, exactly as the file-tree keys do.
final class SurfaceAccountCodingTests: XCTestCase {

    func testDecodesWithoutAccountID() throws {
        let json = #"{"id":"1B9F0A16-0000-0000-0000-000000000001","workingDir":"/tmp"}"#
        let decoded = try JSONDecoder().decode(Surface.self, from: Data(json.utf8))
        XCTAssertNil(decoded.accountID)
        XCTAssertEqual(decoded.workingDir, "/tmp")
    }

    func testRoundTripsAccountID() throws {
        let surface = Surface(workingDir: "/tmp", accountID: "work")
        let data = try JSONEncoder().encode(surface)
        XCTAssertEqual(try JSONDecoder().decode(Surface.self, from: data).accountID, "work")
    }

    func testRoundTripsTheDefaultSentinel() throws {
        let surface = Surface(workingDir: "/tmp", accountID: AgentAccountSupport.defaultID)
        let data = try JSONEncoder().encode(surface)
        XCTAssertEqual(try JSONDecoder().decode(Surface.self, from: data).accountID, "@default")
    }
}
