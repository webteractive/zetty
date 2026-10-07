import Testing
import Foundation
@testable import ZettyCore

@Test func snapshotRoundTripsSpacesAndMembership() {
    let model = WorkspaceModel(homeRoot: "/Users/test")
    model.addProject(name: "acme-api", rootPath: "/tmp/acme-api", makeActive: false)
    model.addProject(name: "loose", rootPath: "/tmp/loose", makeActive: false)
    let space = model.createSpace(name: "Client Acme", colorID: "teal", glyph: "briefcase.fill")!
    let apiIndex = model.projects.firstIndex { $0.name == "acme-api" }!
    model.assign(projectAt: apiIndex, to: space.id)

    let saved = SessionSnapshot.workspace(from: model)
    #expect(saved.spaces == [space])
    #expect(saved.projects.first { $0.name == "acme-api" }?.spaceID == space.id)
    #expect(saved.projects.first { $0.name == "loose" }?.spaceID == nil)

    let runtimes = SessionSnapshot.projectRuntimes(from: saved)
    let restored = WorkspaceModel.restored(from: runtimes, spaces: saved.spaces,
                                           activeIndex: saved.activeProjectIndex,
                                           homeRoot: "/Users/test")!
    #expect(restored.spaces.map(\.name) == ["Client Acme"])
    // Spaces sit BELOW Projects, so spaceless `loose` precedes the member.
    #expect(restored.projects.map(\.name) == ["Home", "loose", "acme-api"])
    #expect(restored.projects(inSpace: restored.spaces[0].id).map(\.name) == ["acme-api"])
}

@Test func restoringWithoutSpacesLeavesEveryProjectUngrouped() {
    let model = WorkspaceModel(homeRoot: "/Users/test")
    model.addProject(name: "solo", rootPath: "/tmp/solo", makeActive: false)
    let saved = SessionSnapshot.workspace(from: model)
    let restored = WorkspaceModel.restored(from: SessionSnapshot.projectRuntimes(from: saved),
                                           homeRoot: "/Users/test")!
    #expect(restored.spaces.isEmpty)
    #expect(restored.projects.allSatisfy { $0.spaceID == nil })
}

@Test func restoringDropsMembershipForAnUnknownSpace() {
    let orphanID = UUID()
    let project = Project(name: "stray", rootPath: "/tmp/stray", spaceID: orphanID)
    let workspace = Workspace(projects: [project], spaces: [])
    let restored = WorkspaceModel.restored(from: SessionSnapshot.projectRuntimes(from: workspace),
                                           spaces: workspace.spaces,
                                           homeRoot: "/Users/test")!
    #expect(restored.projects.first { $0.name == "stray" }?.spaceID == nil)
}

// MARK: - Activity (hibernate-after)

// `hibernate-after` measures from when a project was last used. Kept only in
// memory, every relaunch reset every project's idle clock.
@Test func lastUsedAndKeptAwakeSurviveARoundTrip() throws {
    let model = WorkspaceModel(homeRoot: "/Users/test")
    model.addProject(name: "app", rootPath: "/tmp/app", makeActive: false)
    let app = try #require(model.projects.first { $0.name == "app" })
    app.lastUsedAt = Date(timeIntervalSince1970: 1_000)
    app.keptAwake = true

    let data = try JSONEncoder().encode(SessionSnapshot.workspace(from: model))
    let saved = try JSONDecoder().decode(Workspace.self, from: data)
    let restored = try #require(WorkspaceModel.restored(
        from: SessionSnapshot.projectRuntimes(from: saved), homeRoot: "/Users/test"))
    let back = try #require(restored.projects.first { $0.name == "app" })
    #expect(back.lastUsedAt == Date(timeIntervalSince1970: 1_000))
    #expect(back.keptAwake)
    #expect(restored.projects.first { $0.isHome }?.keptAwake == false)
}

@Test func aWorkspaceSavedBeforeActivityWasRecordedStillLoads() throws {
    let model = WorkspaceModel(homeRoot: "/Users/test")
    model.addProject(name: "app", rootPath: "/tmp/app", makeActive: false)
    let encoded = try JSONEncoder().encode(SessionSnapshot.workspace(from: model))
    var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var projects = try #require(json["projects"] as? [[String: Any]])
    for index in projects.indices {
        projects[index].removeValue(forKey: "lastUsedAt")
        projects[index].removeValue(forKey: "keptAwake")
    }
    json["projects"] = projects
    let saved = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
    let runtimes = SessionSnapshot.projectRuntimes(from: saved)
    #expect(runtimes.allSatisfy { $0.lastUsedAt == nil && !$0.keptAwake })
}
