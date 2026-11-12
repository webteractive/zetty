import Testing
import Foundation
@testable import ZettyCore

// Pinning is gone (2026-11-12): Active replaced the Pinned section. A
// workspace.json saved by an older Zetty still says "isPinned", and must load.

@Test func anOldWorkspaceWithPinnedProjectsLoadsAndKeepsThemFirst() throws {
    let home = UUID().uuidString, pinned = UUID().uuidString, plain = UUID().uuidString
    // An older Zetty kept pinned projects first in the array, which sortOrder
    // records, so a formerly pinned project lands at the top of Projects.
    let json = #"""
    {"schemaVersion":1,"activeProjectIndex":0,"projects":[
      {"id":"\#(home)","name":"Home","rootPath":"/h","isHome":true,"isPinned":false,"sortOrder":0,"sessions":[]},
      {"id":"\#(pinned)","name":"loved","rootPath":"/l","isPinned":true,"sortOrder":1,"sessions":[]},
      {"id":"\#(plain)","name":"other","rootPath":"/o","isPinned":false,"sortOrder":2,"sessions":[]}
    ]}
    """#
    let saved = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
    let model = WorkspaceModel(restoring: SessionSnapshot.projectRuntimes(from: saved), activeIndex: 0)!
    #expect(model.projects.map(\.name) == ["Home", "loved", "other"])
}

@Test func savingAWorkspaceNoLongerWritesIsPinned() throws {
    let model = WorkspaceModel()
    _ = model.addProject(name: "api", rootPath: "/a")
    let data = try JSONEncoder().encode(SessionSnapshot.workspace(from: model))
    #expect(!String(decoding: data, as: UTF8.self).contains("isPinned"))
}

@Test func regroupOrdersHomeThenProjectsThenSpacesThenScratch() {
    let model = WorkspaceModel()
    _ = model.addScratchProject(makeActive: false)
    let space = model.createSpace(name: "Work")!
    _ = model.addProject(name: "member", rootPath: "/m", makeActive: false)
    _ = model.addProject(name: "loose", rootPath: "/l", makeActive: false)
    model.assign(projectAt: model.projects.firstIndex { $0.name == "member" }!, to: space.id)
    #expect(model.projects.map(\.name).dropFirst() == ["loose", "member", "scratch"])
    #expect(model.projects.first?.isHome == true)
}

@Test func removingScratchFallsBackToTheFirstProject() {
    let model = WorkspaceModel(restoring: [
        ProjectRuntime(name: "first", rootPath: "/f"),
        ProjectRuntime(name: "second", rootPath: "/s"),
    ], activeIndex: 1)!
    _ = model.addScratchProject()            // scratch becomes active
    model.removeScratchProjects()
    #expect(model.activeProject.name == "first")
}
