import Testing
import Foundation
@testable import ZettyCore

@Test func spaceDefaultsToNoColorGlyphAndExpanded() {
    let space = Space(name: "Client Acme")
    #expect(space.name == "Client Acme")
    #expect(space.colorID == nil)
    #expect(space.glyph == nil)
    #expect(space.isCollapsed == false)
}

@Test func spaceDecodesTolerantlyFromNameAndIDOnly() throws {
    let id = UUID()
    let json = #"{"id":"\#(id.uuidString)","name":"Side Projects"}"#
    let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))
    #expect(space.id == id)
    #expect(space.name == "Side Projects")
    #expect(space.colorID == nil)
    #expect(space.glyph == nil)
    #expect(space.isCollapsed == false)
}

@Test func projectDefaultsToNoSpace() {
    let project = Project(name: "demo", rootPath: "/tmp/demo")
    #expect(project.spaceID == nil)
}

@Test func projectDecodesWithoutSpaceIDKey() throws {
    let json = #"{"name":"demo","rootPath":"/tmp/demo"}"#
    let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
    #expect(project.spaceID == nil)
}

@Test func workspaceDecodesWithoutSpacesKey() throws {
    let json = #"{"schemaVersion":1,"projects":[]}"#
    let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
    #expect(workspace.spaces.isEmpty)
}

@Test func workspaceRoundTripsSpacesAndMembership() throws {
    let space = Space(name: "Client Acme", colorID: "teal", glyph: "briefcase.fill", isCollapsed: true)
    let project = Project(name: "acme-api", rootPath: "/tmp/acme-api", spaceID: space.id)
    let workspace = Workspace(projects: [project], spaces: [space])
    let data = try JSONEncoder().encode(workspace)
    let decoded = try JSONDecoder().decode(Workspace.self, from: data)
    #expect(decoded.spaces == [space])
    #expect(decoded.projects.first?.spaceID == space.id)
}
