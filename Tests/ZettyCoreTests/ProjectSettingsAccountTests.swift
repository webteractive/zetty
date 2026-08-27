import XCTest
@testable import ZettyCore

final class ProjectSettingsAccountTests: XCTestCase {

    func testDecodesWithoutAccountID() throws {
        let decoded = try JSONDecoder().decode(ProjectSettings.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.accountID)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testAccountIDAloneIsNotAnEmptyRecord() {
        // Otherwise the store would drop a project whose ONLY setting is its account.
        XCTAssertFalse(ProjectSettings(accountID: "work").isEmpty)
    }

    func testResolverSurfacesTheAccountID() {
        let resolved = ProjectSettingsResolver.resolve(
            ProjectSettings(accountID: "work"), fallbackName: "p", global: AppConfig())
        XCTAssertEqual(resolved.accountID, "work")
    }

    func testResolverLeavesAccountNilWhenUnset() {
        let resolved = ProjectSettingsResolver.resolve(
            nil, fallbackName: "p", global: AppConfig())
        XCTAssertNil(resolved.accountID)
    }
}
