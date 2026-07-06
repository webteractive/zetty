import Testing
@testable import ZettyCore

@Test func catalogHasExpectedAgentsAndCommands() {
    let ids = SpawnableAgent.catalog.map(\.id)
    #expect(ids == ["claude", "codex", "hermes", "gemini", "opencode", "pi", "cursor"])
    #expect(SpawnableAgent.byID("cursor")?.defaultCommand == "cursor-agent")
    #expect(SpawnableAgent.byID("claude")?.defaultCommand == "claude")
    #expect(SpawnableAgent.byID("nope") == nil)
}

@Test func resolveDropsUnknownKeepsCatalogOrderAndOverrides() {
    let stored = [
        ProjectAgent(id: "cursor", command: ""),          // blank → default
        ProjectAgent(id: "claude", command: "claude --resume"),
        ProjectAgent(id: "ghost", command: "boo"),        // unknown → dropped
    ]
    let resolved = SpawnableAgent.resolve(stored)
    // Catalog order: claude before cursor; ghost dropped.
    #expect(resolved.map(\.agent.id) == ["claude", "cursor"])
    #expect(resolved.first { $0.agent.id == "claude" }?.command == "claude --resume")
    #expect(resolved.first { $0.agent.id == "cursor" }?.command == "cursor-agent")
}

@Test func resolveEmptyOrNilIsEmpty() {
    #expect(SpawnableAgent.resolve(nil).isEmpty)
    #expect(SpawnableAgent.resolve([]).isEmpty)
}
