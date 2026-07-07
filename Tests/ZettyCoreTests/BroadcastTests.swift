import Foundation
import Testing
@testable import ZettyCore

// MARK: - Target-set resolution

private let a = UUID(), b = UUID(), c = UUID()

@Test func broadcastOffTargetsNothing() {
    let targets = Broadcast.targets(
        scope: .off, currentTabSurfaces: [a, b], allSurfaces: [a, b, c], hasAgent: { _ in true })
    #expect(targets.isEmpty)
}

@Test func broadcastCurrentTabTargetsTheTab() {
    let targets = Broadcast.targets(
        scope: .currentTab, currentTabSurfaces: [a, b], allSurfaces: [a, b, c], hasAgent: { _ in false })
    #expect(targets == [a, b])
}

@Test func broadcastWorkspaceTargetsEverything() {
    let targets = Broadcast.targets(
        scope: .workspace, currentTabSurfaces: [a], allSurfaces: [a, b, c], hasAgent: { _ in false })
    #expect(targets == [a, b, c])
}

@Test func broadcastAgentsTargetsOnlyAgentPanes() {
    let targets = Broadcast.targets(
        scope: .agents, currentTabSurfaces: [a], allSurfaces: [a, b, c], hasAgent: { $0 == b })
    #expect(targets == [b])
}

@Test func broadcastAgentsWithNoAgentsIsEmpty() {
    let targets = Broadcast.targets(
        scope: .agents, currentTabSurfaces: [a], allSurfaces: [a, b, c], hasAgent: { _ in false })
    #expect(targets.isEmpty)
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
