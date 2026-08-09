import Foundation
import Testing
@testable import ZettyCore

@Test func fileTreeIsHiddenByDefault() {
    let surface = Surface(workingDir: "/r")
    #expect(surface.fileTreeVisible == false)
    #expect(surface.fileTreeWidth == nil)
}

/// A `workspace.json` written before this feature must still decode — the pane
/// simply has no tree.
@Test func surfaceFromAnOlderWorkspaceDecodesWithNoFileTree() throws {
    let json = """
    {"id":"7B2C0C1E-0000-4000-8000-000000000001","workingDir":"/Users/x/p"}
    """
    let surface = try JSONDecoder().decode(Surface.self, from: Data(json.utf8))
    #expect(surface.workingDir == "/Users/x/p")
    #expect(surface.fileTreeVisible == false)
    #expect(surface.fileTreeWidth == nil)
}

@Test func fileTreeFieldsSurviveARoundTrip() throws {
    let surface = Surface(workingDir: "/r", command: "zsh", lastTitle: "shell",
                          fileTreeVisible: true, fileTreeWidth: 315)
    let data = try JSONEncoder().encode(surface)
    let decoded = try JSONDecoder().decode(Surface.self, from: data)
    #expect(decoded == surface)
    #expect(decoded.fileTreeVisible == true)
    #expect(decoded.fileTreeWidth == 315)
}

@Test func explicitlyVisibleTreeDecodesFromJSON() throws {
    let json = """
    {"id":"7B2C0C1E-0000-4000-8000-000000000002","workingDir":"/r",
     "fileTreeVisible":true,"fileTreeWidth":260}
    """
    let surface = try JSONDecoder().decode(Surface.self, from: Data(json.utf8))
    #expect(surface.fileTreeVisible == true)
    #expect(surface.fileTreeWidth == 260)
}
