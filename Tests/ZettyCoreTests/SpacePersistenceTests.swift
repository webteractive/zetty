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
