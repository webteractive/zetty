import Foundation

/// Naming, path derivation and validation for `AgentAccount` — the pure half of
/// account creation. Filesystem work lives in the app layer.
public enum AgentAccountSupport {

    /// Reserved id meaning "the agent's own default login — inject nothing".
    ///
    /// Never stored in `agent-accounts.json`: it is synthesized into every
    /// picker so the default is always selectable, and it resolves to an EMPTY
    /// environment so the pane inherits the process environment exactly as it
    /// did before accounts existed. The `@` prefix is what makes it collision
    /// proof — `slug` cannot emit one — mirroring `ProjectSettingsStore.homeKey`.
    public static let defaultID = "@default"

    /// The only agent with a verified isolation variable today.
    public static let defaultAgentID = "claude"

    /// `[a-z0-9-]` only; shared with clone naming so the two agree.
    public static func slug(_ name: String) -> String {
        CloneSupport.slug(name)
    }

    /// `~/.zetty/accounts` — beside `clones/`, `hooks/` and `panes/`, and free
    /// of spaces by construction, which matters because the path is rendered
    /// into a one-line ghostty directive.
    public static func accountsRoot(home: String) -> String {
        (home as NSString).appendingPathComponent(".zetty/accounts")
    }

    public static func defaultDirectory(home: String, slug: String) -> String {
        (accountsRoot(home: home) as NSString).appendingPathComponent(slug)
    }

    /// Tilde expanded, `.`/`..` resolved, no trailing slash — the form two paths
    /// are compared in. Deliberately does NOT resolve symlinks: the account
    /// directory usually doesn't exist yet when it is validated.
    public static func canonical(_ path: String, home: String) -> String {
        var expanded = path
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = (home as NSString).appendingPathComponent(String(expanded.dropFirst(2)))
        }
        let standardized = (expanded as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast()) : standardized
    }

    /// The inverse, so the stored file stays portable across machines.
    public static func abbreviate(_ path: String, home: String) -> String {
        let canonical = canonical(path, home: home)
        guard canonical == home || canonical.hasPrefix(home + "/") else { return canonical }
        return "~" + canonical.dropFirst(home.count)
    }

    public enum ValidationError: Error, Equatable {
        case blankName
        case duplicateName
        case duplicateDirectory
        case relativeDirectory
        case directoryIsAgentHome
        case directoryIsHomeOrAncestor
        case directoryHasUnsafeCharacters
    }

    /// Builds a validated account, or the first rule it breaks.
    ///
    /// `directory` nil means "manage it for me" — `~/.zetty/accounts/<slug>`.
    public static func make(
        name: String,
        directory: String?,
        agentID: String,
        colorID: String?,
        existing: [AgentAccount],
        home: String
    ) -> Result<AgentAccount, ValidationError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = slug(trimmedName)
        guard !trimmedName.isEmpty, !id.isEmpty else { return .failure(.blankName) }

        guard !existing.contains(where: {
            $0.name.lowercased() == trimmedName.lowercased() || $0.id == id
        }) else { return .failure(.duplicateName) }

        let raw = directory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = (raw?.isEmpty == false ? raw! : defaultDirectory(home: home, slug: id))
        guard chosen.hasPrefix("/") || chosen.hasPrefix("~") else {
            return .failure(.relativeDirectory)
        }

        // Checked BEFORE canonicalization so the message describes what was typed.
        guard isSafeDirectoryPath(chosen) else { return .failure(.directoryHasUnsafeCharacters) }

        let canonicalDir = canonical(chosen, home: home)
        let canonicalHome = canonical(home, home: home)

        // `~/.claude` IS the default account. An account pointing there would
        // hash to a different Keychain item than the real default login while
        // looking identical in every picker.
        if let agentHome = agentHomeDirectory(agentID: agentID, home: home),
           canonicalDir == agentHome {
            return .failure(.directoryIsAgentHome)
        }

        // Home itself, or anything above it, would put credentials somewhere
        // enormous and shared. (`isAncestor` covers "/" and "/Users".)
        if canonicalDir == canonicalHome || isAncestor(canonicalDir, of: canonicalHome) {
            return .failure(.directoryIsHomeOrAncestor)
        }

        guard !existing.contains(where: {
            canonical($0.directory, home: home) == canonicalDir
        }) else { return .failure(.duplicateDirectory) }

        return .success(AgentAccount(
            id: id,
            name: trimmedName,
            colorID: colorID,
            directory: abbreviate(canonicalDir, home: home),
            agentID: agentID))
    }

    /// Where the agent keeps its config when no account is chosen.
    public static func agentHomeDirectory(agentID: String, home: String) -> String? {
        guard let name = SpawnableAgent.byID(agentID)?.defaultConfigDirName else { return nil }
        return canonical((home as NSString).appendingPathComponent(name), home: home)
    }

    /// The account directory is rendered into `env = KEY=<dir>`, a single line
    /// in a config libghostty validates all-or-nothing. A rejected directive
    /// frees the WHOLE config including the per-surface `command`, stranding
    /// preserved sessions — so the path is restricted to characters that are
    /// unambiguously safe there, rather than trusted and repaired later.
    private static func isSafeDirectoryPath(_ path: String) -> Bool {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/~")
        return path.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Whether `candidate` is a strict ancestor directory of `path`.
    private static func isAncestor(_ candidate: String, of path: String) -> Bool {
        if candidate == "/" { return path != "/" }
        return path.hasPrefix(candidate + "/")
    }
}
