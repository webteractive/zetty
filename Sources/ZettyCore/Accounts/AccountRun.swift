import Foundation

/// Everything needed to launch an account's harness in the current terminal.
/// Pure: the CLI performs the `mkdir` and the `execvp`.
public struct AccountRunPlan: Equatable, Sendable {
    /// The account's display name, as stored — used for messages and ZETTY_ACCOUNT.
    public let accountName: String
    /// The account id, so the caller can report the override to the app.
    public let accountID: String
    /// The harness to exec, from the agent catalog (e.g. "claude").
    public let command: String
    /// Everything the user typed after the account name, verbatim.
    public let arguments: [String]
    /// The config-dir variable plus ZETTY_ACCOUNT.
    public let environment: [String: String]
    /// Must exist before the exec: Codex refuses to start when CODEX_HOME names
    /// a directory that does not exist. nil when the agent isolates no config.
    public let configDirectory: String?
}

public enum AccountRunError: Error, Equatable, Sendable {
    case noAccountsConfigured
    /// Carries the known account names so the CLI can list them.
    case unknownAccount(String, available: [String])
    case agentNotInCatalog(agentID: String, accountName: String)
}

/// Resolves "run this account" into a concrete plan.
///
/// An unknown name is an ERROR rather than a fall-through to the default login:
/// landing an agent on the wrong account is the mistake accounts exist to
/// prevent, and the same rule already governs `--account` on new-tab/split.
public enum AccountRun {

    /// Environment variable naming the account a process was launched under.
    /// Informational — a shell prompt or a bug report can read it.
    public static let accountEnvVar = "ZETTY_ACCOUNT"

    public static func plan(
        accountName: String,
        arguments: [String],
        accounts: [AgentAccount],
        home: String
    ) -> Result<AccountRunPlan, AccountRunError> {
        guard !accounts.isEmpty else { return .failure(.noAccountsConfigured) }

        let file = AgentAccountsFile(accounts: accounts)
        guard let account = file.account(named: accountName) else {
            return .failure(.unknownAccount(accountName, available: accounts.map(\.name)))
        }
        guard let agent = SpawnableAgent.byID(account.agentID) else {
            return .failure(.agentNotInCatalog(agentID: account.agentID,
                                               accountName: account.name))
        }

        // Reuses the single place the account → environment rule lives, so
        // `zetty run` and a stamped pane can never disagree about the variable.
        let resolution = AgentAccountResolver.resolution(for: account, home: home)
        var environment = resolution.env
        environment[accountEnvVar] = account.name

        let configDirectory = agent.configDirEnvVar.map { key in
            environment[key] ?? AgentAccountSupport.canonical(account.directory, home: home)
        }

        return .success(AccountRunPlan(
            accountName: account.name,
            accountID: account.id,
            command: agent.defaultCommand,
            arguments: arguments,
            environment: environment,
            configDirectory: configDirectory))
    }
}
