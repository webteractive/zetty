import Foundation
import Testing
@testable import ZettyCore

// MARK: - Target-set resolution

private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

private func resolve(_ scope: BroadcastScope, hasAgent: @escaping (UUID) -> Bool = { _ in false }) -> [UUID] {
    Broadcast.targets(
        scope: scope,
        currentTabSurfaces: [a],
        currentProjectSurfaces: [a, b],
        allSurfaces: [a, b, c, d],
        hasAgent: hasAgent)
}

@Test func broadcastOffTargetsNothing() {
    #expect(resolve(.off, hasAgent: { _ in true }).isEmpty)
}

@Test func broadcastCurrentTabTargetsTheTab() {
    #expect(resolve(.currentTab) == [a])
}

@Test func broadcastProjectTargetsTheProject() {
    #expect(resolve(.project) == [a, b])
}

@Test func broadcastWorkspaceTargetsEverything() {
    #expect(resolve(.workspace) == [a, b, c, d])
}

@Test func broadcastAgentsTargetsOnlyAgentPanes() {
    #expect(resolve(.agents, hasAgent: { $0 == c }) == [c])
}

@Test func broadcastAgentsWithNoAgentsIsEmpty() {
    #expect(resolve(.agents).isEmpty)
}

@Test func broadcastScopeCodeRoundTrips() {
    for scope in [BroadcastScope.currentTab, .project, .agents, .workspace] {
        #expect(BroadcastScope(code: scope.code) == scope)
    }
    #expect(BroadcastScope.off.code == nil)
    #expect(BroadcastScope(code: nil) == .off)
    #expect(BroadcastScope(code: "bogus") == .off)
}

@Test func broadcastScopeCyclesOffTabProjectAgentsWorkspace() {
    #expect(BroadcastScope.off.next == .currentTab)
    #expect(BroadcastScope.currentTab.next == .project)
    #expect(BroadcastScope.project.next == .agents)
    #expect(BroadcastScope.agents.next == .workspace)
    #expect(BroadcastScope.workspace.next == .off)
}

// MARK: - Chord → terminal bytes

private func bytes(_ chord: String) -> String? {
    KeyChord.parse(chord)!.terminalBytes
}

@Test func terminalBytesEncodesLettersControlAndNamedKeys() {
    #expect(bytes("a") == "a")
    #expect(bytes("G") == "G")                 // shift baked into the character
    #expect(bytes("ctrl+c") == "\u{03}")       // C0 control byte
    #expect(bytes("enter") == "\r")
    #expect(bytes("tab") == "\t")
    #expect(bytes("shift+tab") == "\u{1b}[Z")
    #expect(bytes("escape") == "\u{1b}")
    #expect(bytes("up") == "\u{1b}[A")
    #expect(bytes("left") == "\u{1b}[D")
}

@Test func terminalBytesSkipsCmdAndAltCombos() {
    #expect(bytes("cmd+c") == nil)
    #expect(bytes("alt+x") == nil)
}
