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

/// What a resume line has to change about the shell it is typed into, so the
/// harness comes back under the login it was running as.
public struct ResumeLogin: Equatable, Sendable {
    /// Assigned in front of the harness: an account the shell does not hold.
    public let environment: [String: String]
    /// Removed for the harness: the shell holds an account and the DEFAULT
    /// login was running, which is expressed by the variable being absent.
    public let unsetting: [String]

    public init(environment: [String: String] = [:], unsetting: [String] = []) {
        self.environment = environment
        self.unsetting = unsetting
    }

    /// The shell already is that login, so the line carries nothing — which
    /// also leaves a hand-typed project env var alone.
    public static let inherited = ResumeLogin()
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
            // A hook can report the DEFAULT login running in a pane spawned on
            // an account; that is an answer, not a gap to fall through.
            if candidate == AgentAccountSupport.defaultID { return .default }
            guard let candidate,
                  let account = accounts.first(where: { $0.id == candidate }),
                  account.agentID == agentID else { continue }
            return resolution(for: account, home: home)
        }
        return .default
    }

    /// How a resume must adjust the pane's shell for `agentID` to come back
    /// under the login it was running as. The shell holds the SPAWN account's
    /// env, so only a difference between the two needs saying.
    public static func resumeLogin(
        agentID: String,
        runningAccountID: String?,
        spawnedAccountID: String?,
        accounts: [AgentAccount],
        home: String
    ) -> ResumeLogin {
        let running = harnessAccount(agentID: agentID, runningAccountID: runningAccountID,
                                     spawnedAccountID: spawnedAccountID,
                                     accounts: accounts, home: home)
        let shell = harnessAccount(agentID: agentID, runningAccountID: nil,
                                   spawnedAccountID: spawnedAccountID,
                                   accounts: accounts, home: home)
        guard running.accountID != shell.accountID else { return .inherited }
        return running.isDefault
            ? ResumeLogin(unsetting: shell.env.keys.sorted())
            : ResumeLogin(environment: running.env)
    }

    /// The account a harness's hook says it is running under, from the value
    /// of its config-dir variable: `defaultID` when the variable is unset or
    /// names the harness's own home, the matching account's id otherwise.
    ///
    /// nil when there is nothing to name — the harness hosts no accounts, or
    /// the directory is one Zetty has no account for. The caller then leaves
    /// what it shows alone rather than guessing.
    public static func accountID(
        forReportedConfigDirectory directory: String,
        agentID: String,
        accounts: [AgentAccount],
        home: String
    ) -> String? {
        guard SpawnableAgent.byID(agentID)?.configDirEnvVar != nil else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return AgentAccountSupport.defaultID }
        let reported = AgentAccountSupport.canonical(trimmed, home: home)
        if reported == AgentAccountSupport.agentHomeDirectory(agentID: agentID, home: home) {
            return AgentAccountSupport.defaultID
        }
        return accounts.first {
            $0.agentID == agentID
                && AgentAccountSupport.canonical($0.directory, home: home) == reported
        }?.id
    }

    /// What `Surface.runningAccountID` should hold once a hook has reported
    /// `reported`: nothing when that is the account the pane was spawned
    /// with, since the override exists only to say the two differ.
    public static func runningOverride(reported: String, spawned: String?) -> String? {
        reported == spawned ? nil : reported
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
