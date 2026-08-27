import Foundation

/// A named login for an agent harness — "Work" and "Personal" Claude accounts,
/// each with its own config directory.
///
/// One environment variable does the whole job: Claude Code derives its macOS
/// Keychain service name from `CLAUDE_CONFIG_DIR`
/// (`Claude Code-credentials-<sha256(dir)[0:8]>`), so pointing a pane at a
/// different directory gives it its own Keychain item, its own `.claude.json`
/// (which holds the account identity), and its own history — without Zetty ever
/// touching the Keychain or the default login.
public struct AgentAccount: Codable, Sendable, Equatable, Identifiable {
    /// Slug derived from the name at creation. Stable: a rename keeps the id, so
    /// panes and project settings referring to it don't break.
    public let id: String
    /// Display name. Unique case-insensitively — it is the CLI's handle, the
    /// same rule Space names follow.
    public var name: String
    /// A `ZTheme.projectPalette` id, so accounts and projects share one palette.
    public var colorID: String?
    /// Stored tilde-abbreviated so the file stays portable between machines.
    public var directory: String
    /// Which catalog agent this account belongs to; selects the env var to set.
    public var agentID: String
    /// Captured once at sign-in, never polled — see `AuthStatusProbe`.
    public var lastKnownEmail: String?
    public var lastKnownOrg: String?

    public init(
        id: String,
        name: String,
        colorID: String? = nil,
        directory: String,
        agentID: String = AgentAccountSupport.defaultAgentID,
        lastKnownEmail: String? = nil,
        lastKnownOrg: String? = nil
    ) {
        self.id = id
        self.name = name
        self.colorID = colorID
        self.directory = directory
        self.agentID = agentID
        self.lastKnownEmail = lastKnownEmail
        self.lastKnownOrg = lastKnownOrg
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorID, directory, agentID, lastKnownEmail, lastKnownOrg
    }

    /// Hand-written so a file from an older (or newer, or hand-edited) build
    /// still decodes — the same tolerance `Surface` and `Space` rely on.
    /// `encode(to:)` stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        directory = try c.decode(String.self, forKey: .directory)
        colorID = try c.decodeIfPresent(String.self, forKey: .colorID)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
            ?? AgentAccountSupport.defaultAgentID
        lastKnownEmail = try c.decodeIfPresent(String.self, forKey: .lastKnownEmail)
        lastKnownOrg = try c.decodeIfPresent(String.self, forKey: .lastKnownOrg)
    }
}

/// The on-disk shape of `agent-accounts.json`.
///
/// Array order is picker order, mirroring `WorkspaceModel.spaces` — there is
/// deliberately no second ordering field to disagree with it.
public struct AgentAccountsFile: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var accounts: [AgentAccount]

    public init(schemaVersion: Int = 1, accounts: [AgentAccount] = []) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, accounts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        accounts = try c.decodeIfPresent([AgentAccount].self, forKey: .accounts) ?? []
    }

    public func account(id: String) -> AgentAccount? {
        accounts.first { $0.id == id }
    }

    /// Case-insensitive by name, then by id — how the CLI addresses an account.
    public func account(named name: String) -> AgentAccount? {
        let wanted = name.lowercased()
        return accounts.first { $0.name.lowercased() == wanted }
            ?? accounts.first { $0.id.lowercased() == wanted }
    }

    public func accounts(forAgent agentID: String) -> [AgentAccount] {
        accounts.filter { $0.agentID == agentID }
    }

    /// Replaces in place when the id is known, so a rename keeps picker order.
    public mutating func upsert(_ account: AgentAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    public mutating func remove(id: String) {
        accounts.removeAll { $0.id == id }
    }
}
