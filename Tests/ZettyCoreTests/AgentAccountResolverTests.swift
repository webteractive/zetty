import XCTest
@testable import ZettyCore

final class AgentAccountResolverTests: XCTestCase {

    private let home = "/Users/tester"

    private let work = AgentAccount(id: "work", name: "Work", colorID: "sky",
                                    directory: "~/.zetty/accounts/work", agentID: "claude")
    private let personal = AgentAccount(id: "personal", name: "Personal", colorID: "moss",
                                        directory: "~/.zetty/accounts/personal", agentID: "claude")

    private func resolve(pane: String?, project: String?,
                         accounts: [AgentAccount]? = nil) -> AccountResolution {
        AgentAccountResolver.resolve(paneAccountID: pane, projectAccountID: project,
                                     accounts: accounts ?? [work, personal], home: home)
    }

    func testPaneOverrideBeatsProjectDefault() {
        let r = resolve(pane: "personal", project: "work")
        XCTAssertEqual(r.accountID, "personal")
        XCTAssertEqual(r.env, ["CLAUDE_CONFIG_DIR": "/Users/tester/.zetty/accounts/personal"])
    }

    func testProjectDefaultAppliesWhenThePaneHasNoOverride() {
        XCTAssertEqual(resolve(pane: nil, project: "work").accountID, "work")
    }

    func testDefaultAccountInjectsNoEnv() {
        let r = resolve(pane: nil, project: nil)
        XCTAssertTrue(r.isDefault)
        XCTAssertEqual(r.accountID, AgentAccountSupport.defaultID)
        XCTAssertEqual(r.displayName, "Default")
        XCTAssertNil(r.colorID)
        XCTAssertTrue(r.env.isEmpty)
    }

    func testExplicitDefaultSentinelIsTheSameAsNil() {
        XCTAssertEqual(resolve(pane: AgentAccountSupport.defaultID, project: "work").accountID,
                       AgentAccountSupport.defaultID)
    }

    /// A deleted account must never strand a pane — it falls through, it does
    /// not error and does not keep a dangling id.
    func testUnknownPaneAccountFallsThroughToTheProjectDefault() {
        XCTAssertEqual(resolve(pane: "deleted", project: "work").accountID, "work")
    }

    func testUnknownProjectAccountFallsThroughToDefault() {
        XCTAssertTrue(resolve(pane: nil, project: "deleted").isDefault)
    }

    func testResolvedDirectoryIsExpandedNotTilde() {
        let dir = resolve(pane: "work", project: nil).env["CLAUDE_CONFIG_DIR"]
        XCTAssertEqual(dir, "/Users/tester/.zetty/accounts/work")
        XCTAssertFalse(dir!.contains("~"))
    }

    /// The env var comes from the agent catalog, so an account for an agent with
    /// no known isolation variable injects nothing rather than guessing a name.
    func testAgentWithoutAConfigDirEnvVarInjectsNothing() {
        // Hermes has no verified isolation variable, so an account naming it
        // resolves normally but sets nothing — never a guessed variable name.
        let hermes = AgentAccount(id: "hx", name: "Hermes Work", colorID: nil,
                                  directory: "~/.zetty/accounts/hx", agentID: "hermes")
        let r = resolve(pane: "hx", project: nil, accounts: [hermes])
        XCTAssertEqual(r.accountID, "hx")
        XCTAssertEqual(r.displayName, "Hermes Work")
        XCTAssertTrue(r.env.isEmpty)
    }

    /// Codex isolates through `CODEX_HOME`, with credentials in a file inside
    /// the directory rather than the Keychain.
    func testCodexAccountSetsCodexHome() {
        let codex = AgentAccount(id: "cx", name: "Codex Work", colorID: nil,
                                 directory: "~/.zetty/accounts/cx", agentID: "codex")
        let r = resolve(pane: "cx", project: nil, accounts: [codex])
        XCTAssertEqual(r.env, ["CODEX_HOME": "/Users/tester/.zetty/accounts/cx"])
    }

    func testResolutionCarriesDisplayNameAndColor() {
        let r = resolve(pane: "work", project: nil)
        XCTAssertEqual(r.displayName, "Work")
        XCTAssertEqual(r.colorID, "sky")
        XCTAssertFalse(r.isDefault)
    }
}

extension AgentAccountResolverTests {

    /// Chrome shows the harness's logo beside the account name, so the
    /// resolution has to carry which harness it is.
    func testResolutionCarriesTheAgent() {
        let work = AgentAccount(id: "work", name: "Work", colorID: "sky",
                                directory: "~/.zetty/accounts/work", agentID: "claude")
        let r = AgentAccountResolver.resolve(paneAccountID: "work", projectAccountID: nil,
                                             accounts: [work], home: "/Users/tester")
        XCTAssertEqual(r.agentID, "claude")
    }

    /// The default login isn't tied to one harness.
    func testDefaultResolutionHasNoAgent() {
        XCTAssertNil(AccountResolution.default.agentID)
    }

    // MARK: - harnessAccount

    private var codexWork: AgentAccount {
        AgentAccount(id: "codex-work", name: "Codex Work", colorID: nil,
                     directory: "~/.zetty/accounts/codex-work", agentID: "codex")
    }

    private func harness(_ agent: String, running: String?, spawned: String?) -> AccountResolution {
        AgentAccountResolver.harnessAccount(agentID: agent, runningAccountID: running,
                                            spawnedAccountID: spawned,
                                            accounts: [work, personal, codexWork], home: home)
    }

    func testTheZettyRunOverrideBeatsTheSpawnAccount() {
        let r = harness("claude", running: "personal", spawned: "work")
        XCTAssertEqual(r.accountID, "personal")
        XCTAssertEqual(r.env, ["CLAUDE_CONFIG_DIR": "/Users/tester/.zetty/accounts/personal"])
    }

    func testAReportedDefaultLoginIsNotAGapToFallThrough() {
        // The default login running in a pane spawned on an account.
        XCTAssertTrue(harness("claude", running: AgentAccountSupport.defaultID,
                              spawned: "work").isDefault)
    }

    // MARK: - resumeLogin

    private func login(_ agent: String, running: String?, spawned: String?) -> ResumeLogin {
        AgentAccountResolver.resumeLogin(agentID: agent, runningAccountID: running,
                                         spawnedAccountID: spawned,
                                         accounts: [work, personal, codexWork], home: home)
    }

    func testAResumeInheritsTheShellWhenTheRunningLoginIsTheSpawnOne() {
        XCTAssertEqual(login("claude", running: nil, spawned: "work"), .inherited)
        XCTAssertEqual(login("claude", running: nil, spawned: nil), .inherited)
        XCTAssertEqual(login("claude", running: AgentAccountSupport.defaultID, spawned: nil),
                       .inherited)
    }

    func testAResumeAssignsAnAccountTheShellDoesNotHold() {
        XCTAssertEqual(login("claude", running: "personal", spawned: "work"),
                       ResumeLogin(environment: [
                           "CLAUDE_CONFIG_DIR": "/Users/tester/.zetty/accounts/personal"]))
    }

    func testAResumeDropsTheShellsAccountForTheDefaultLogin() {
        XCTAssertEqual(login("claude", running: AgentAccountSupport.defaultID, spawned: "work"),
                       ResumeLogin(unsetting: ["CLAUDE_CONFIG_DIR"]))
    }

    func testAResumeLeavesAnotherHarnessesAccountAlone() {
        // The shell's CODEX_HOME is not Claude's to remove.
        XCTAssertEqual(login("claude", running: AgentAccountSupport.defaultID,
                             spawned: "codex-work"), .inherited)
    }

    // MARK: - reported config directory

    private func reported(_ directory: String, agent: String = "claude") -> String? {
        AgentAccountResolver.accountID(forReportedConfigDirectory: directory, agentID: agent,
                                       accounts: [work, personal, codexWork], home: home)
    }

    func testAnUnsetVariableIsTheDefaultLogin() {
        XCTAssertEqual(reported(""), AgentAccountSupport.defaultID)
    }

    func testTheHarnessOwnHomeIsTheDefaultLogin() {
        XCTAssertEqual(reported("/Users/tester/.claude"), AgentAccountSupport.defaultID)
        XCTAssertEqual(reported("~/.codex/", agent: "codex"), AgentAccountSupport.defaultID)
    }

    func testAnAccountDirectoryNamesItsAccount() {
        XCTAssertEqual(reported("/Users/tester/.zetty/accounts/personal"), "personal")
        XCTAssertEqual(reported("~/.zetty/accounts/work/"), "work")
        XCTAssertEqual(reported("/Users/tester/.zetty/accounts/codex-work", agent: "codex"),
                       "codex-work")
    }

    func testADirectoryIsOnlyMatchedAgainstItsOwnHarness() {
        XCTAssertNil(reported("/Users/tester/.zetty/accounts/codex-work"))
    }

    func testAnUnknownDirectoryNamesNothing() {
        XCTAssertNil(reported("/Users/tester/somewhere-else"))
    }

    func testAHarnessWithoutAccountsNamesNothing() {
        XCTAssertNil(reported("", agent: "hermes"))
    }

    func testTheOverrideIsOnlyHeldWhenItDiffersFromTheSpawnAccount() {
        XCTAssertNil(AgentAccountResolver.runningOverride(reported: "work", spawned: "work"))
        XCTAssertEqual(AgentAccountResolver.runningOverride(reported: "personal", spawned: "work"),
                       "personal")
        XCTAssertEqual(AgentAccountResolver.runningOverride(
            reported: AgentAccountSupport.defaultID, spawned: "work"),
                       AgentAccountSupport.defaultID)
    }

    func testTheSpawnAccountAppliesWithNoOverride() {
        XCTAssertEqual(harness("claude", running: nil, spawned: "work").accountID, "work")
    }

    func testAnotherHarnessesAccountSaysNothingAboutThisOne() {
        // A Codex login's CODEX_HOME does not decide which Claude login runs.
        XCTAssertEqual(harness("claude", running: "codex-work", spawned: "work").accountID, "work")
        XCTAssertTrue(harness("claude", running: nil, spawned: "codex-work").isDefault)
        XCTAssertEqual(harness("codex", running: "codex-work", spawned: "work").accountID, "codex-work")
    }

    func testAnUnknownAccountFallsThroughToTheDefaultLogin() {
        XCTAssertTrue(harness("claude", running: "gone", spawned: nil).isDefault)
    }
}
