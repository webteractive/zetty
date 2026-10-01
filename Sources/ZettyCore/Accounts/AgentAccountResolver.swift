import Foundation

/// What account actually applies to a pane, and the environment that expresses it.
public struct AccountResolution: Equatable, Sendable {
    /// `AgentAccountSupport.defaultID` or a real account id.
    public let accountID: String
    public let displayName: String
    public let colorID: String?
    /// Which harness this account belongs to, so chrome can show its logo.
    /// nil for the default account, which isn't tied to one.
    public let agentID: String?
    public let isDefault: Bool
    /// Empty for the default account — the pane then inherits the process
    /// environment untouched, exactly as it did before accounts existed.
    public let env: [String: String]

    public init(accountID: String, displayName: String, colorID: String?,
                agentID: String? = nil, isDefault: Bool, env: [String: String]) {
        self.accountID = accountID
        self.displayName = displayName
        self.colorID = colorID
        self.agentID = agentID
        self.isDefault = isDefault
        self.env = env
    }

    public static let `default` = AccountResolution(
        accountID: AgentAccountSupport.defaultID,
        displayName: "Default",
        colorID: nil,
        agentID: nil,
        isDefault: true,
        env: [:])
}

/// The single place the precedence rule lives: pane override → project default
/// → the agent's own default login.
public enum AgentAccountResolver {

    public static func resolve(
        paneAccountID: String?,
        projectAccountID: String?,
        accounts: [AgentAccount],
        home: String
    ) -> AccountResolution {
        // Each level falls THROUGH when its id names an account that no longer
        // exists, rather than erroring or holding on to a dangling id: removing
        // an account must never strand a pane.
        for candidate in [paneAccountID, projectAccountID] {
            guard let candidate, !candidate.isEmpty else { continue }
            if candidate == AgentAccountSupport.defaultID { return .default }
            guard let account = accounts.first(where: { $0.id == candidate }) else { continue }
            return resolution(for: account, home: home)
        }
        return .default
    }

    /// The login a pane's `agentID` harness is running under: the `zetty run`
    /// override first, then the account the pane was spawned with — each only
    /// when it belongs to THAT harness, since a Codex account's `CODEX_HOME`
    /// says nothing about which Claude login shares the pane. `.default` when
    /// neither applies.
    ///
    /// A restart must come back under this login, not the pane's spawn env:
    /// after `zetty run` the shell still carries the spawn account, so a bare
    /// resume would reopen the conversation under the wrong login — or fail to
    /// find it, since each config dir keeps its own transcripts.
    public static func harnessAccount(
        agentID: String,
        runningAccountID: String?,
        spawnedAccountID: String?,
        accounts: [AgentAccount],
        home: String
    ) -> AccountResolution {
        for candidate in [runningAccountID, spawnedAccountID] {
            guard let candidate,
                  let account = accounts.first(where: { $0.id == candidate }),
                  account.agentID == agentID else { continue }
            return resolution(for: account, home: home)
        }
        return .default
    }

    public static func resolution(for account: AgentAccount, home: String) -> AccountResolution {
        var env: [String: String] = [:]
        // The variable name comes from the agent catalog. An agent with no known
        // isolation variable injects NOTHING — never a guessed name.
        if let key = SpawnableAgent.byID(account.agentID)?.configDirEnvVar {
            env[key] = AgentAccountSupport.canonical(account.directory, home: home)
        }
        return AccountResolution(
            accountID: account.id,
            displayName: account.name,
            colorID: account.colorID,
            agentID: account.agentID,
            isDefault: false,
            env: env)
    }
}
