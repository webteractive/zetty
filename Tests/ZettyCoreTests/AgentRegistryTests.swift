import Testing
@testable import ZettyCore

@Test func registryCoversAllSixAgents() {
    #expect(Set(AgentRegistry.all.map(\.kind)) == Set(AgentKind.allCases))
}

@Test func matchesBareCommandName() {
    #expect(AgentRegistry.match(command: "claude")?.kind == .claude)
}

@Test func matchesFullPathByLastComponent() {
    #expect(AgentRegistry.match(command: "/opt/homebrew/bin/codex")?.kind == .codex)
}

@Test func matchIsCaseInsensitive() {
    #expect(AgentRegistry.match(command: "OpenCode")?.kind == .opencode)
}

@Test func unknownCommandReturnsNil() {
    #expect(AgentRegistry.match(command: "/bin/zsh") == nil)
}
