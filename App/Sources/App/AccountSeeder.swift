import Foundation
import ZettyGhostty

/// Creates an account's config directory and seeds it from the agent's default
/// one, so a new account isn't a stripped-down install.
///
/// The pure half — what may be shared, what may never be, and how — lives in
/// `AccountSeed`. This is only the filesystem work, and it is deliberately
/// conservative: it never overwrites, never deletes, and reports every item so a
/// partial seed is visible rather than silent.
///
/// Blocking IO. Call off the main thread.
enum AccountSeeder {

    enum Result: Equatable {
        case linked(String)
        case copied(String)
        /// Preference keys carried into the account's own config file.
        case seededPreferences([String])
        case sourceMissing(String)
        case destinationExists(String)
        case refusedUnsafe(String)
        case failed(String, reason: String)

        var itemID: String {
            switch self {
            case let .linked(id), let .copied(id), let .sourceMissing(id),
                 let .destinationExists(id), let .refusedUnsafe(id), let .failed(id, _):
                return id
            case .seededPreferences:
                return ".claude.json"
            }
        }

        /// Whether this needs telling the user about.
        ///
        /// `destinationExists` deliberately does NOT: the item is already there
        /// and was left untouched, which is the correct outcome. The common way
        /// to reach it is re-adding an account that was removed — removal keeps
        /// the directory, so its links and settings survive — and alarming
        /// someone about every item working as intended is worse than silence.
        var isProblem: Bool {
            switch self {
            case .linked, .copied, .sourceMissing, .destinationExists, .seededPreferences:
                return false
            case .refusedUnsafe, .failed:
                return true
            }
        }
    }

    /// Creates `account.directory` (0700) and seeds the selected items.
    ///
    /// Returns one result per attempted item. Creating the directory is the only
    /// step that can fail the whole call — everything else degrades to a
    /// reported per-item outcome, because a missing skill folder is not a reason
    /// to refuse someone an account.
    static func prepare(
        account: AgentAccount,
        selections: Set<String>,
        home: String = NSHomeDirectory()
    ) throws -> [Result] {
        let destinationRoot = AgentAccountSupport.canonical(account.directory, home: home)
        try FileManager.default.createDirectory(
            atPath: destinationRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        guard let sourceName = SpawnableAgent.byID(account.agentID)?.defaultConfigDirName else {
            return []
        }
        let sourceRoot = AgentAccountSupport.canonical(
            (home as NSString).appendingPathComponent(sourceName), home: home)

        var results = AccountSeed.plan(selecting: selections, forAgent: account.agentID)
            .map { seed($0, from: sourceRoot, to: destinationRoot, agentID: account.agentID) }
        if let preferences = seedPreferences(
            from: home, to: destinationRoot, agentID: account.agentID) {
            results.append(preferences)
        }
        return results
    }

    /// Carries a few non-identity preferences into the account's `.claude.json`,
    /// most importantly `hasCompletedOnboarding`.
    ///
    /// Without it a fully signed-in account still greets you with the first-run
    /// login selector: `claude auth login` writes credentials but never marks
    /// onboarding complete, and interactive `claude` runs onboarding whenever
    /// that flag is missing — so a working account looks broken.
    ///
    /// Safe to call repeatedly and on an account that already exists: it fills
    /// only keys the account LACKS, so a re-run is a no-op and an account made
    /// before this existed repairs itself on its next sign-in.
    @discardableResult
    static func seedPreferences(from home: String, to destinationRoot: String,
                                agentID: String = "claude") -> Result? {
        // Claude-only today: Codex keeps no equivalent JSON we can seed.
        guard let fileName = AccountSeed.preferenceFileName(forAgent: agentID) else { return nil }
        // The agent's own config file sits BESIDE its config dir; an account's
        // sits INSIDE it (both are `<CLAUDE_CONFIG_DIR>/.claude.json`, and the
        // default config dir is the home directory).
        let sourceURL = URL(fileURLWithPath: home).appendingPathComponent(fileName)
        let destinationURL = URL(fileURLWithPath: destinationRoot)
            .appendingPathComponent(fileName)

        guard let defaults = readJSON(sourceURL) else { return nil }
        var account = readJSON(destinationURL) ?? [:]

        let keys = AccountSeed.preferenceKeysToSeed(
            available: Set(defaults.keys), existing: Set(account.keys))
        guard !keys.isEmpty else { return nil }
        for key in keys { account[key] = defaults[key] }

        do {
            let data = try JSONSerialization.data(
                withJSONObject: account, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destinationURL, options: .atomic)
            return .seededPreferences(keys)
        } catch {
            return .failed(fileName, reason: error.localizedDescription)
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func seed(_ item: AccountSeed.Item,
                             from sourceRoot: String,
                             to destinationRoot: String,
                             agentID: String) -> Result {
        let fm = FileManager.default
        let source = (sourceRoot as NSString).appendingPathComponent(item.id)
        let destination = (destinationRoot as NSString).appendingPathComponent(item.id)

        // Re-checked here even though `plan` already filtered: the sheet's check
        // and this run are seconds apart, and this is the last gate before the
        // filesystem.
        guard AccountSeed.isShareable(item.id, forAgent: agentID) else {
            return .refusedUnsafe(item.id)
        }

        // The destination may be a real directory the user populated by hand, or
        // a link from an earlier seed. Either way it is theirs, not ours.
        guard !fm.fileExists(atPath: destination),
              (try? fm.destinationOfSymbolicLink(atPath: destination)) == nil
        else { return .destinationExists(item.id) }

        guard fm.fileExists(atPath: source) else { return .sourceMissing(item.id) }

        // A source that resolves INSIDE the account directory would make a
        // self-referential link — the kind that makes a directory walk spin
        // forever.
        let resolvedSource = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
        if resolvedSource == destinationRoot || resolvedSource.hasPrefix(destinationRoot + "/") {
            return .refusedUnsafe(item.id)
        }

        do {
            switch item.treatment {
            case .symlink:
                // Point at `source`, NOT `resolvedSource`: on this machine
                // `~/.claude/agents` is itself a link into a dotfiles repo, and
                // linking straight to the repo would break if that repo moves.
                // A link to a link resolves fine.
                try fm.createSymbolicLink(atPath: destination, withDestinationPath: source)
                return .linked(item.id)
            case .copy:
                try fm.copyItem(atPath: source, toPath: destination)
                return .copied(item.id)
            }
        } catch {
            return .failed(item.id, reason: error.localizedDescription)
        }
    }
}
