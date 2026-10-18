import Foundation
import Testing
@testable import ZettyCore

/// Handing a pane's work to a fresh session (`zetty handoff`, `/z-handoff`):
/// which login it lands on, the line that starts it, and when its brief goes.

private let work = AgentAccount(id: "work", name: "Work", directory: "~/.zetty/accounts/work", agentID: "claude")
private let side = AgentAccount(id: "side", name: "Side Codex", directory: "~/.zetty/accounts/side", agentID: "codex")
private let accounts = [work, side]

private func target(_ name: String?, from agent: AgentKind = .claude,
                    on account: String = AgentAccountSupport.defaultID) -> AgentHandoff.Target? {
    try? AgentHandoff.resolve(name, current: agent, currentAccountID: account, accounts: accounts).get()
}

@Test func noTargetIsAFreshSessionOnTheSameLogin() {
    #expect(target(nil, on: "work") == .init(agent: .claude, accountID: "work"))
    #expect(target("  ", from: .codex) == .init(agent: .codex, accountID: AgentAccountSupport.defaultID))
}

@Test func aHarnessNameIsItsDefaultLogin() {
    #expect(target("codex", on: "work") == .init(agent: .codex, accountID: AgentAccountSupport.defaultID))
    #expect(target("Claude", from: .codex) == .init(agent: .claude, accountID: AgentAccountSupport.defaultID))
}

/// `/z-handoff claude-devops`: the handle the menu and the mod list, and the
/// account's own `claude-<account>` command.
@Test func anAccountIsFoundByItsHandleOrItsCommandName() {
    #expect(target("claude-work") == .init(agent: .claude, accountID: "work"))
    #expect(target("codex-side") == .init(agent: .codex, accountID: "side"))
    #expect(target("codex-side-codex") == .init(agent: .codex, accountID: "side"))
    #expect(AgentHandoff.targets(accounts: accounts).map(\.name) == ["claude", "claude-work", "codex", "codex-side"])
}

@Test func anAccountIsFoundByNameOrIdAndCarriesItsHarness() {
    #expect(target("work") == .init(agent: .claude, accountID: "work"))
    #expect(target("side codex") == .init(agent: .codex, accountID: "side"))
    #expect(target("SIDE") == .init(agent: .codex, accountID: "side"))
}

/// Landing on the wrong login is what accounts exist to prevent.
@Test func anUnknownTargetIsAnErrorNamingTheChoices() {
    let result = AgentHandoff.resolve("wrk", current: .claude, currentAccountID: "work", accounts: accounts)
    #expect(result == .failure(.unknownTarget("wrk", choices: ["claude", "codex", "claude-work", "codex-side"])))
}

@Test func anAccountOfAnotherHarnessCannotBeHandedTo() {
    let gemini = AgentAccount(id: "g", name: "G", directory: "~/.zetty/accounts/g", agentID: "gemini")
    let result = AgentHandoff.resolve("g", current: .claude, currentAccountID: "work", accounts: [gemini])
    #expect(result == .failure(.unsupportedAgent("G")))
}

@Test func theMenuListsEachHarnessDefaultThenItsAccounts() {
    let titles = AgentHandoff.targets(accounts: accounts).map(\.title)
    #expect(titles == ["Claude · Default", "Claude · Work", "Codex · Default", "Codex · Side Codex"])
}

@Test func theBriefLivesUnderZettyPerPane() {
    let surface = UUID(uuidString: "5E1FF1E6-DC30-44F3-BF75-1C63EE728E52")!
    #expect(AgentHandoff.briefPath(for: surface, home: "/Users/me")
        == "/Users/me/.zetty/transfers/5E1FF1E6-DC30-44F3-BF75-1C63EE728E52.md")
}

/// A newline typed into a harness's box would submit the request half-written.
@Test func bothPromptsAreOneLineNamingTheBrief() {
    for prompt in [AgentHandoff.writePrompt(briefPath: "/b.md"), AgentHandoff.readPrompt(briefPath: "/b.md")] {
        #expect(!prompt.contains("\n"))
        #expect(prompt.contains("/b.md"))
    }
}

@Test func theLaunchLineStartsTheHarnessOnItsFirstPromptUnderTheLogin() {
    let line = AgentHandoff.launchLine(agent: .codex, login: ResumeLogin(environment: ["CODEX_HOME": "/a/side"]),
                                       cwd: "/tmp/it's", briefPath: "/b.md")
    #expect(line == "cd '/tmp/it'\\''s' && CODEX_HOME='/a/side' codex 'Read the handoff brief at /b.md: "
        + "a previous session working here wrote it for you. Say in a few lines where things stand, "
        + "then continue with its next step.'")
    let toDefault = AgentHandoff.launchLine(agent: .claude, login: ResumeLogin(unsetting: ["CLAUDE_CONFIG_DIR"]),
                                            cwd: "/w", briefPath: "/b.md")
    #expect(toDefault?.hasPrefix("cd '/w' && env -u CLAUDE_CONFIG_DIR claude 'Read") == true)
    #expect(AgentHandoff.launchLine(agent: .aider, login: .inherited, cwd: "/w", briefPath: "/b.md") == nil)
}

// Claude reports idle as it starts, before it has read anything.
@Test func aClaudeBriefGoesAfterItsFirstTurnNotAtItsStart() {
    var brief = PendingBrief(path: "/b.md", agent: .claude)
    let atStart = brief.observe(.idle)
    let turnStarted = brief.observe(.running)
    let turnEnded = brief.observe(.idle)
    #expect(!atStart)
    #expect(!turnStarted)
    #expect(turnEnded)
}

// Codex's one hook is turn ended.
@Test func aCodexBriefGoesAtItsFirstTurnEnded() {
    var brief = PendingBrief(path: "/b.md", agent: .codex)
    let turnEnded = brief.observe(.idle)
    #expect(turnEnded)
}

@Test func aBriefGoesWhenTheSessionEndsUnread() {
    var brief = PendingBrief(path: "/b.md", agent: .claude)
    let ended = brief.observe(.ended)
    #expect(ended)
}

// MARK: - The quit line left in the box

/// Codex kept the Enter typed with `/quit` as a newline, and the handoff
/// waited out its 30 seconds with Codex running. The retry presses Enter only
/// when the line is seen sitting there.
@Test func aQuitLineSittingInTheBoxIsSeen() {
    let codex = "  Worked for 23s\n› /quit\n  GPT-6 high · /tmp/x\n"
    #expect(PromptBox.boxHolds("/quit", vtScreen: codex, agent: .codex))
    let claude = "⏺ done\n────────\n❯ /exit\n────────\n  Opus | /tmp/x\n"
    #expect(PromptBox.boxHolds("/exit", vtScreen: claude, agent: .claude))
}

@Test func anythingElseInTheBoxIsNotTheQuitLine() {
    #expect(!PromptBox.boxHolds("/quit", vtScreen: "› \n", agent: .codex))
    #expect(!PromptBox.boxHolds("/quit", vtScreen: "› /quit now\n", agent: .codex))
    #expect(!PromptBox.boxHolds("/exit", vtScreen: "────────\n❯ \n────────\n", agent: .claude))
}

/// After the agent has quit the screen is a shell, and an Enter there would
/// type into it.
@Test func aShellIsNotABoxHoldingTheLine() {
    #expect(!PromptBox.boxHolds("/exit", vtScreen: "➜  h1 /exit\n❯ /exit\n", agent: .claude))
    #expect(!PromptBox.boxHolds("/quit", vtScreen: "➜  h1 \n", agent: .codex))
}
