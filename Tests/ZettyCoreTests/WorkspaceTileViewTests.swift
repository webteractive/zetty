import Foundation
import Testing
@testable import ZettyCore

@Test func aWorkspaceRemembersWhichTileViewsWereOpen() throws {
    var workspace = Workspace()
    let ids = [UUID(), UUID()]
    workspace.openTileViewIDs = ids
    workspace.activeTileViewIndex = 1
    let data = try JSONEncoder().encode(workspace)
    let decoded = try JSONDecoder().decode(Workspace.self, from: data)
    #expect(decoded.openTileViewIDs == ids)
    #expect(decoded.activeTileViewIndex == 1)
}

@Test func anOlderWorkspaceHasNoOpenTileViews() throws {
    let json = #"{"schemaVersion":1,"projects":[]}"#
    let decoded = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
    #expect(decoded.openTileViewIDs.isEmpty)
    #expect(decoded.activeTileViewIndex == 0)
}
