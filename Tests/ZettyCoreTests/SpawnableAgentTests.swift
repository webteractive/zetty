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

@Test func spawnConfigCarriesAgentsAndPromptFlag() {
    let on = SpawnableAgent.spawnConfig(agents: [ProjectAgent(id: "claude", command: "claude")], promptOnNewPane: true)
    #expect(on.promptOnNewPane)
    #expect(on.agents.map(\.agent.id) == ["claude"])

    let off = SpawnableAgent.spawnConfig(agents: [ProjectAgent(id: "claude", command: "claude")], promptOnNewPane: false)
    #expect(!off.promptOnNewPane)
    #expect(AgentSpawnConfig.disabled.agents.isEmpty)
    #expect(!AgentSpawnConfig.disabled.promptOnNewPane)
}

/// Tight chrome (the status chip, the Accounts list) needs a compact label:
/// "Claude Code" and "Cursor Agent" are longer than the space deserves.
@Test func shortNamesAreCompact() {
    #expect(SpawnableAgent.byID("claude")?.shortName == "Claude")
    #expect(SpawnableAgent.byID("cursor")?.shortName == "Cursor")
}

/// Agents whose name is already short don't need a second one.
@Test func shortNameDefaultsToTheDisplayName() {
    for id in ["codex", "hermes", "gemini", "opencode", "pi"] {
        let agent = SpawnableAgent.byID(id)
        #expect(agent?.shortName == agent?.displayName)
    }
}
