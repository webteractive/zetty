import XCTest
@testable import ZettyCore

final class WorkspaceAccountHealingTests: XCTestCase {

    private func workspace() -> WorkspaceModel {
        WorkspaceModel(homeRoot: "/Users/tester")
    }

    func testFindsASurfaceAcrossProjects() {
        let model = workspace()
        let id = model.activeTabList.activeTree.layout.surfaces[0].id
        XCTAssertEqual(model.surface(with: id)?.id, id)
        XCTAssertNil(model.surface(with: UUID()))
    }

    func testClearsAccountIDsPointingAtARemovedAccount() {
        let model = workspace()
        let id = model.activeTabList.activeTree.layout.surfaces[0].id
        model.activeTabList.updateSurface(id) { $0.accountID = "deleted" }

        XCTAssertTrue(model.healAccountIDs(known: ["work"]))
        XCTAssertNil(model.surface(with: id)?.accountID)
    }

    func testKeepsKnownAccountsAndTheDefaultSentinel() {
        let model = workspace()
        let id = model.activeTabList.activeTree.layout.surfaces[0].id

        model.activeTabList.updateSurface(id) { $0.accountID = "work" }
        XCTAssertFalse(model.healAccountIDs(known: ["work"]))
        XCTAssertEqual(model.surface(with: id)?.accountID, "work")

        model.activeTabList.updateSurface(id) { $0.accountID = AgentAccountSupport.defaultID }
        XCTAssertFalse(model.healAccountIDs(known: []))
        XCTAssertEqual(model.surface(with: id)?.accountID, AgentAccountSupport.defaultID)
    }
}
