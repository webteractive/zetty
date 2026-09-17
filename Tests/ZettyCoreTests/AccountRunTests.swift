import Testing
@testable import ZettyCore

private let home = "/Users/tester"

private func account(_ name: String, agent: String = "claude") -> AgentAccount {
    AgentAccount(id: AgentAccountSupport.slug(name), name: name,
                 directory: "~/.zetty/accounts/\(AgentAccountSupport.slug(name))",
                 agentID: agent)
}

private func isSuccess(_ result: Result<AccountRunPlan, AccountRunError>) -> Bool {
    if case .success = result { return true }
    return false
}

@Test func planResolvesClaudeAccountToCommandAndConfigDir() {
    let result = AccountRun.plan(accountName: "Personal", arguments: [],
                                 accounts: [account("Personal")], home: home)
    guard case .success(let plan) = result else { Issue.record("expected success"); return }
    #expect(plan.command == "claude")
    #expect(plan.accountName == "Personal")
    #expect(plan.accountID == "personal")
    #expect(plan.environment["CLAUDE_CONFIG_DIR"] == "\(home)/.zetty/accounts/personal")
    #expect(plan.environment["ZETTY_ACCOUNT"] == "Personal")
    #expect(plan.configDirectory == "\(home)/.zetty/accounts/personal")
}

@Test func planResolvesCodexAccountToItsOwnVariable() {
    let result = AccountRun.plan(accountName: "Work", arguments: [],
                                 accounts: [account("Work", agent: "codex")], home: home)
    guard case .success(let plan) = result else { Issue.record("expected success"); return }
    #expect(plan.command == "codex")
    #expect(plan.environment["CODEX_HOME"] == "\(home)/.zetty/accounts/work")
    #expect(plan.environment["CLAUDE_CONFIG_DIR"] == nil)
}

// Passthrough must be verbatim — including arguments that collide with zetty's
// own flags. `zetty run personal --focus` means `claude --focus`, never zetty's
// --focus.
@Test func planPassesArgumentsThroughVerbatim() {
    let args = ["--resume", "--focus", "--json", "-p", "hello world"]
    let result = AccountRun.plan(accountName: "Personal", arguments: args,
                                 accounts: [account("Personal")], home: home)
    guard case .success(let plan) = result else { Issue.record("expected success"); return }
    #expect(plan.arguments == args)
}

@Test func planLooksUpCaseInsensitivelyAndByID() {
    let accounts = [account("Personal")]
    #expect(isSuccess(AccountRun.plan(accountName: "PERSONAL", arguments: [],
                                      accounts: accounts, home: home)))
    #expect(isSuccess(AccountRun.plan(accountName: "personal", arguments: [],
                                      accounts: accounts, home: home)))
}

// The one place tolerance is wrong: an unknown name must never fall back to the
// default login. The error carries the known names so the CLI can list them.
@Test func planRejectsUnknownAccountAndListsAvailable() {
    let result = AccountRun.plan(accountName: "nope", arguments: [],
                                 accounts: [account("Personal"), account("Work")], home: home)
    guard case .failure(let error) = result else { Issue.record("expected failure"); return }
    #expect(error == .unknownAccount("nope", available: ["Personal", "Work"]))
}

@Test func planRejectsWhenNoAccountsConfigured() {
    let result = AccountRun.plan(accountName: "personal", arguments: [],
                                 accounts: [], home: home)
    #expect(result == .failure(.noAccountsConfigured))
}

@Test func planRejectsAccountWhoseAgentLeftTheCatalog() {
    let stale = AgentAccount(id: "old", name: "Old", directory: "~/.zetty/accounts/old",
                             agentID: "nonesuch")
    let result = AccountRun.plan(accountName: "Old", arguments: [],
                                 accounts: [stale], home: home)
    #expect(result == .failure(.agentNotInCatalog(agentID: "nonesuch", accountName: "Old")))
}
