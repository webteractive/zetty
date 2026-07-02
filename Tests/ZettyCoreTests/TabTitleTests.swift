import Testing
import Foundation
@testable import ZettyCore

@Test func tabTitlePrefersManual() {
    #expect(TabTitle.display(manualTitle: "mine", focusedSurfaceTitle: "vim", workingDir: "/x", index: 0) == "mine")
}

@Test func tabTitleShowsRunningCommandOverPwd() {
    // A real running command (terminal title) names the tab, over the pwd.
    #expect(TabTitle.display(manualTitle: nil, focusedSurfaceTitle: "vim", workingDir: "/x/y", index: 0) == "vim")
}

@Test func tabTitleIdleShellFallsBackToPwd() {
    // A bare shell name means "idle at a prompt" → show the pwd, not "zsh".
    #expect(TabTitle.display(manualTitle: nil, focusedSurfaceTitle: "zsh", workingDir: "/x/y", index: 0) == "y")
    #expect(TabTitle.display(manualTitle: nil, focusedSurfaceTitle: "-zsh", workingDir: "/x/y", index: 0) == "y")
}

@Test func tabTitleAgentPrefixesTheEmittedTitle() {
    // Agent identity + the title the CLI emits → "claude code: <emits>".
    #expect(TabTitle.display(manualTitle: nil, agentName: "claude code", focusedSurfaceTitle: "✳ fixing tests", workingDir: "/x/y", index: 0) == "claude code: ✳ fixing tests")
}

@Test func tabTitleAgentAloneWhenNoUsefulTitle() {
    // No emitted title (or just a shell name) → the agent name stands alone.
    #expect(TabTitle.display(manualTitle: nil, agentName: "codex", focusedSurfaceTitle: nil, workingDir: "/x/y", index: 0) == "codex")
    #expect(TabTitle.display(manualTitle: nil, agentName: "codex", focusedSurfaceTitle: "-zsh", workingDir: "/x/y", index: 0) == "codex")
    #expect(TabTitle.display(manualTitle: nil, agentName: "codex", focusedSurfaceTitle: "  ", workingDir: "/x/y", index: 0) == "codex")
}

@Test func tabTitleUsesCommandWhenNoWorkingDir() {
    #expect(TabTitle.display(manualTitle: nil, focusedSurfaceTitle: "vim", workingDir: nil, index: 0) == "vim")
}

@Test func tabTitleFallsBackToWorkingDirBasename() {
    #expect(TabTitle.display(manualTitle: nil, focusedSurfaceTitle: "  ", workingDir: "/Users/me/web", index: 0) == "web")
}

@Test func tabTitleFallsBackToPositional() {
    #expect(TabTitle.display(manualTitle: " ", focusedSurfaceTitle: nil as String?, workingDir: nil as String?, index: 2) == "Tab 3")
}

@Test func tabTitleRootDirFallsBackToPositional() {
    // "/" has no meaningful basename -> should fall through to positional.
    #expect(TabTitle.display(manualTitle: nil, focusedSurfaceTitle: nil, workingDir: "/", index: 0) == "Tab 1")
}

@Test func paneTreeManualTitleDefaultsNilAndIsCodable() throws {
    var t = PaneTree(layout: Layout(root: .leaf(Surface(workingDir: "/x"))))
    #expect(t.manualTitle == nil)
    t.manualTitle = "named"
    let data = try JSONEncoder().encode(t)
    let back = try JSONDecoder().decode(PaneTree.self, from: data)
    #expect(back.manualTitle == "named")
}
