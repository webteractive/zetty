import Testing
import Foundation
@testable import ZettyCore

@Test func addCloneProjectSlotsAfterItsSource() {
    let ws = WorkspaceModel()                                  // [Home]
    ws.addProject(name: "alpha", rootPath: "/tmp/alpha")       // [Home, alpha]
    ws.addProject(name: "beta", rootPath: "/tmp/beta")         // [Home, alpha, beta]
    ws.addCloneProject(name: "alpha/fork-1", rootPath: "/tmp/c/alpha-fork-1",
                       cloneSource: "/tmp/alpha")
    #expect(ws.projects.map(\.name) == ["Home", "alpha", "alpha/fork-1", "beta"])
    // Background by default: active project unchanged (beta was active).
    #expect(ws.activeProject.name == "beta")
}

@Test func clonesOfReturnsOnlyMatchingClones() {
    let ws = WorkspaceModel()
    let alpha = ws.addProject(name: "alpha", rootPath: "/tmp/alpha")
    ws.addCloneProject(name: "alpha/fork-1", rootPath: "/tmp/c/a1", cloneSource: "/tmp/alpha")
    ws.addCloneProject(name: "alpha/fork-2", rootPath: "/tmp/c/a2", cloneSource: "/tmp/alpha")
    ws.addProject(name: "beta", rootPath: "/tmp/beta")
    #expect(ws.clones(of: alpha).map(\.name) == ["alpha/fork-1", "alpha/fork-2"])
}

@Test func orphanedCloneStaysAsOrdinaryRow() {
    let ws = WorkspaceModel()
    ws.addProject(name: "alpha", rootPath: "/tmp/alpha")
    ws.addCloneProject(name: "alpha/fork-1", rootPath: "/tmp/c/a1", cloneSource: "/tmp/alpha")
    let alphaIndex = ws.projects.firstIndex { $0.name == "alpha" }!
    ws.removeProject(at: alphaIndex)
    // Clone survives, keeps its cloneSource marker, is freely removable.
    let orphan = ws.projects.first { $0.name == "alpha/fork-1" }
    #expect(orphan != nil)
    #expect(orphan?.cloneSource == "/tmp/alpha")
    let orphanIndex = ws.projects.firstIndex { $0.name == "alpha/fork-1" }!
    ws.removeProject(at: orphanIndex)
    #expect(!ws.projects.contains { $0.name == "alpha/fork-1" })
}

@Test func cloneFollowsItsSourceThroughAReorder() {
    let ws = WorkspaceModel()
    ws.addProject(name: "alpha", rootPath: "/tmp/alpha")
    ws.addProject(name: "beta", rootPath: "/tmp/beta")
    ws.addCloneProject(name: "alpha/fork-1", rootPath: "/tmp/c/a1", cloneSource: "/tmp/alpha")
    // Move beta above alpha: the clone must stay glued to alpha.
    let betaIndex = ws.projects.firstIndex { $0.name == "beta" }!
    let alphaIndex = ws.projects.firstIndex { $0.name == "alpha" }!
    ws.moveProject(from: betaIndex, to: alphaIndex)
    ws.reapplyOrdering()
    #expect(ws.projects.map(\.name) == ["Home", "beta", "alpha", "alpha/fork-1"])
}

@Test func cloneSourceSurvivesPersistenceRoundTrip() {
    let ws = WorkspaceModel()
    ws.addProject(name: "alpha", rootPath: "/tmp/alpha")
    ws.addCloneProject(name: "alpha/fork-1", rootPath: "/tmp/c/a1", cloneSource: "/tmp/alpha")
    let persisted = SessionSnapshot.workspace(from: ws)
    let restored = SessionSnapshot.projectRuntimes(from: persisted)
    let clone = restored.first { $0.name == "alpha/fork-1" }
    #expect(clone?.cloneSource == "/tmp/alpha")
    let normal = restored.first { $0.name == "alpha" }
    #expect(normal?.cloneSource == nil)
}

@Test func oldWorkspaceJSONWithoutCloneSourceDecodes() throws {
    let json = """
    {"id":"\(UUID().uuidString)","name":"legacy","rootPath":"/tmp/legacy"}
    """
    let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
    #expect(project.cloneSource == nil)
}
