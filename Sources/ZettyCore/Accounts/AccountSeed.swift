import Foundation

/// What may be shared from the agent's default config directory into a new
/// account's, and — just as important — what may never be.
///
/// A fresh config directory starts EMPTY: no settings, no skills, no commands.
/// Sharing the read-mostly parts is what stops a second account being a
/// stripped-down install. But "shareable" is not one category, and treating it
/// as one quietly couples two accounts' mutable state:
///
/// - **Symlinked** — read-mostly content both accounts only consume.
/// - **Copied** — `settings.json`, which the agent itself rewrites (plugin
///   enable/disable, onboarding flags). A shared link is last-writer-wins
///   between two live processes; a copy also gives each account a real file for
///   Zetty's own agent hooks to live in, which is what keeps status dots working.
/// - **Never shared** — `plugins/` is a mutable state store (marketplace JSON, a
///   catalog cache, git clones and temp dirs), and identity files, which carry
///   the login itself.
public enum AccountSeed {

    public enum Treatment: String, Sendable, Equatable {
        case symlink
        case copy
    }

    public struct Item: Sendable, Equatable, Identifiable {
        /// Path relative to the config directory, on both sides.
        public let id: String
        public let displayName: String
        public let isDirectory: Bool
        public let treatment: Treatment
        /// Always seeded, not offered as a choice.
        public let isRequired: Bool
        public let detail: String

        public init(id: String, displayName: String, isDirectory: Bool,
                    treatment: Treatment, isRequired: Bool = false, detail: String) {
            self.id = id
            self.displayName = displayName
            self.isDirectory = isDirectory
            self.treatment = treatment
            self.isRequired = isRequired
            self.detail = detail
        }
    }

    /// What a Claude Code account may share.
    public static let claudeShareable: [Item] = [
        .init(id: "settings.json", displayName: "Settings", isDirectory: false,
              treatment: .copy, isRequired: true,
              detail: "Copied — each account needs its own, so agent status hooks work"),
        .init(id: "skills", displayName: "Skills", isDirectory: true,
              treatment: .symlink, detail: "Shared live"),
        .init(id: "commands", displayName: "Commands", isDirectory: true,
              treatment: .symlink, detail: "Shared live"),
        .init(id: "agents", displayName: "Agents", isDirectory: true,
              treatment: .symlink, detail: "Shared live"),
        .init(id: "CLAUDE.md", displayName: "CLAUDE.md", isDirectory: false,
              treatment: .symlink, detail: "Shared live"),
    ]

    /// Never linked, never copied. A HARD denylist kept deliberately separate
    /// from `shareable`, so that adding an item there later cannot leak
    /// credentials or cross-contaminate history by omission.
    /// Never linked, never copied, for Claude Code.
    public static let claudeIdentity: Set<String> = [
        ".claude.json",
        ".claude.json.backup",
        ".credentials.json",
        "projects",
        "history.jsonl",
        "sessions",
        "session-env",
        "todos",
        "statsig",
        "stats-cache.json",
        "shell-snapshots",
        "file-history",
        "ide",
        // A mutable state store, not content: two processes writing through one
        // link corrupts marketplace and catalog state.
        "plugins",
    ]

    /// Preference keys carried from the agent's own `.claude.json` into a new
    /// account's, so a second login behaves like an established install rather
    /// than a brand-new one.
    ///
    /// This exists because `claude auth login` authenticates WITHOUT marking
    /// onboarding complete, and a fresh config directory has no onboarding
    /// state — so interactive `claude` runs its first-run flow, which OPENS
    /// WITH a login prompt. The account is fully signed in; it just looks like
    /// it isn't. Carrying `hasCompletedOnboarding` is the fix; the rest spares
    /// the user re-answering machine-level questions they've already answered.
    ///
    /// An ALLOWLIST, deliberately: identity (`oauthAccount`, `userID`,
    /// `machineID`, `anonymousId`), history (`projects`) and the account-scoped
    /// subscription caches can never ride along, because nothing not named here
    /// is copied at all.
    /// Only Claude Code keeps its onboarding state in a JSON file Zetty can
    /// seed. Codex has no equivalent, so its accounts carry none.
    public static func preferenceKeys(forAgent agentID: String) -> [String] {
        agentID == "claude" ? preferenceKeys : []
    }

    /// The config file an agent's preferences live in, relative to its config
    /// dir. nil = nothing to seed.
    public static func preferenceFileName(forAgent agentID: String) -> String? {
        agentID == "claude" ? ".claude.json" : nil
    }

    public static let preferenceKeys: [String] = [
        "hasCompletedOnboarding",
        "theme",
        "autoUpdates",
        "hasAcknowledgedCostThreshold",
        "shiftEnterKeyBindingInstalled",
        "optionAsMetaKeyInstalled",
    ]

    /// Identity and history keys, named only so a test can assert they are not
    /// reachable through `preferenceKeys`. Nothing reads this at runtime.
    public static let neverCopiedKeys: Set<String> = [
        "oauthAccount", "userID", "anonymousId", "machineID", "projects",
        "mcpServers", "modelAccessCache", "s1mAccessCache", "passesEligibilityCache",
        "hasAvailableSubscription", "subscriptionNoticeCount", "history",
    ]

    /// Which preference keys to copy, given what the source offers and what the
    /// account already has.
    ///
    /// Returns KEYS rather than values so this stays pure and type-agnostic —
    /// these are a mix of booleans and strings, and the caller copies each
    /// value across verbatim.
    ///
    /// Fills only what is MISSING: an account that has already chosen a theme
    /// keeps it, and re-running is a no-op. That is what makes it safe to call
    /// on every sign-in, which is how an account created before this existed
    /// repairs itself.
    public static func preferenceKeysToSeed(
        available: Set<String>,
        existing: Set<String>
    ) -> [String] {
        preferenceKeys.filter { available.contains($0) && !existing.contains($0) }
    }

    /// Codex keeps credentials in `auth.json` inside its config dir, and most
    /// of that directory is state: session transcripts, a dozen SQLite files,
    /// caches and lock directories. Only the user's own instructions and
    /// content are shareable.
    public static let codexShareable: [Item] = [
        .init(id: "config.toml", displayName: "Config", isDirectory: false,
              treatment: .copy, isRequired: true,
              detail: "Copied — each account needs its own, so agent status hooks work"),
        .init(id: "AGENTS.md", displayName: "AGENTS.md", isDirectory: false,
              treatment: .symlink, detail: "Shared live"),
        .init(id: "skills", displayName: "Skills", isDirectory: true,
              treatment: .symlink, detail: "Shared live"),
        .init(id: "rules", displayName: "Rules", isDirectory: true,
              treatment: .symlink, detail: "Shared live"),
    ]

    /// Never linked, never copied, for Codex. `auth.json` is the login itself;
    /// the rest is history, machine state or a mutable store.
    public static let codexIdentity: Set<String> = [
        "auth.json",
        "installation_id",
        ".codex-global-state.json",
        "history.jsonl",
        "sessions",
        "archived_sessions",
        "session_index.jsonl",
        "shell_snapshots",
        "cache",
        "log",
        "tmp",
        ".tmp",
        // A mutable state store, exactly like Claude's `plugins/`.
        "plugins",
        "memories",
        "app-server-control",
        "app-server-daemon",
        "mcp-oauth-locks",
        "thread-writer-locks",
    ]

    /// The shareable items for an agent; empty for one that can't host accounts.
    public static func shareable(forAgent agentID: String) -> [Item] {
        switch agentID {
        case "claude": return claudeShareable
        case "codex":  return codexShareable
        default:       return []
        }
    }

    /// The hard denylist for an agent. Anything not explicitly shareable is
    /// already excluded; this exists so a future addition to a shareable list
    /// cannot leak credentials by omission.
    public static func identity(forAgent agentID: String) -> Set<String> {
        switch agentID {
        case "claude": return claudeIdentity
        case "codex":  return codexIdentity
        default:       return []
        }
    }

    public static func isShareable(_ relativePath: String, forAgent agentID: String) -> Bool {
        guard !identity(forAgent: agentID).contains(relativePath),
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("..")
        else { return false }
        return shareable(forAgent: agentID).contains { $0.id == relativePath }
    }

    /// Required items always; optional ones only when selected. Unknown or
    /// denied selections are dropped before anything touches the filesystem, so
    /// a caller cannot smuggle in an identity path.
    public static func plan(selecting ids: Set<String>, forAgent agentID: String) -> [Item] {
        shareable(forAgent: agentID).filter {
            $0.isRequired || (ids.contains($0.id) && isShareable($0.id, forAgent: agentID))
        }
    }
}
