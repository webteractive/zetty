import Foundation

/// Pure planning for surviving a macOS restart / shutdown / logout.
///
/// At a power-off quit the App layer captures each preserved pane's scrollback
/// and asks `Manifest.make` to tally it with the harness session the pane's
/// agent last reported. The manifest is the ONLY signal that sessions died
/// from a power-off: it is written only then, and the next launch deletes it
/// the moment it is read. Its absence means "sessions may still be alive" —
/// a plain quit, a crash, a panic — and follows the ordinary launch path.
public enum RestartRecovery {

    public static let currentVersion = 1

    /// How long a power-off quit may spend capturing snapshots before the
    /// manifest is written with whatever finished and the reply is sent. An
    /// app that stalls a shutdown is a bug the user meets at the login window.
    public static let shutdownBudget: TimeInterval = 5

    /// `<zmx session name>.vt`, inside the App layer's snapshots directory.
    public static func snapshotFileName(for surfaceID: UUID) -> String {
        SessionPersistence.sessionName(for: surfaceID) + ".vt"
    }

    /// One pane's recoverable state. Everything but `surface` is optional so a
    /// manifest from a newer build never throws on an older one.
    public struct Entry: Codable, Equatable, Sendable {
        public let surface: UUID
        public let snapshot: String?
        public let agent: AgentKind?
        public let agentSession: String?
        public let agentCwd: String?
        /// The account the harness was RUNNING under, when not the default
        /// login — which, after `zetty run`, is not the account the pane was
        /// spawned with. See `pinnedLogin(for:spawnedAccountID:accounts:home:)`.
        public let agentAccount: String?

        public init(surface: UUID, snapshot: String?, agent: AgentKind?,
                    agentSession: String?, agentCwd: String?, agentAccount: String? = nil) {
            self.surface = surface
            self.snapshot = snapshot
            self.agent = agent
            self.agentSession = agentSession
            self.agentCwd = agentCwd
            self.agentAccount = agentAccount
        }

        private enum CodingKeys: String, CodingKey {
            case surface, snapshot, agent, agentSession, agentCwd, agentAccount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            surface = try c.decode(UUID.self, forKey: .surface)
            snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot)
            // An agent kind this build doesn't know decodes as "no agent"
            // rather than failing the whole file.
            agent = try c.decodeIfPresent(String.self, forKey: .agent).flatMap(AgentKind.init(rawValue:))
            agentSession = try c.decodeIfPresent(String.self, forKey: .agentSession)
            agentCwd = try c.decodeIfPresent(String.self, forKey: .agentCwd)
            agentAccount = try c.decodeIfPresent(String.self, forKey: .agentAccount)
        }
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public let version: Int
        public let writtenAt: Date
        public let entries: [Entry]

        public init(version: Int, writtenAt: Date, entries: [Entry]) {
            self.version = version
            self.writtenAt = writtenAt
            self.entries = entries
        }

        /// The tally. `surfaces` are the panes considered (session owners); a
        /// surface with neither a snapshot nor a known harness session has
        /// nothing to recover and is omitted. Order follows `surfaces`.
        /// `agentAccounts` is the account each pane's harness runs under; it is
        /// recorded only beside a session, since nothing else resumes.
        public static func make(
            surfaces: [UUID],
            snapshots: [UUID: String],
            agentStates: [UUID: AgentState],
            agentAccounts: [UUID: String] = [:],
            now: Date
        ) -> Manifest {
            let entries: [Entry] = surfaces.compactMap { id in
                let snapshot = snapshots[id]
                let state = agentStates[id]
                let session = state?.session
                guard snapshot != nil || session != nil else { return nil }
                return Entry(
                    surface: id,
                    snapshot: snapshot,
                    agent: session == nil ? nil : state?.kind,
                    agentSession: session?.id,
                    agentCwd: session?.cwd,
                    agentAccount: session == nil ? nil : agentAccounts[id])
            }
            return Manifest(version: currentVersion, writtenAt: now, entries: entries)
        }

        private static var encoder: JSONEncoder {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            return e
        }

        private static var decoder: JSONDecoder {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }

        public func encoded() -> Data? { try? Self.encoder.encode(self) }

        /// nil for garbage or a version this build doesn't understand — the
        /// caller treats both as "no manifest".
        public static func decode(_ data: Data) -> Manifest? {
            guard let m = try? decoder.decode(Manifest.self, from: data),
                  m.version == currentVersion else { return nil }
            return m
        }

        /// Reconciles against the restored workspace: entries whose surface no
        /// longer exists are dropped, and their snapshot files are reported so
        /// the caller can delete them.
        public func entries(applyingTo known: Set<UUID>) -> (kept: [Entry], droppedSnapshotPaths: [String]) {
            var kept: [Entry] = []
            var dropped: [String] = []
            for entry in entries {
                if known.contains(entry.surface) {
                    kept.append(entry)
                } else if let path = entry.snapshot {
                    dropped.append(path)
                }
            }
            return (kept, dropped)
        }
    }

    /// The login a recovered resume is pinned to: the account to show for the
    /// pane, and what the resume line must change to get there.
    public struct PinnedLogin: Equatable, Sendable {
        public let accountID: String
        public let login: ResumeLogin
    }

    /// The login a recovered resume must be pinned to, or nil when the pane's
    /// own spawn env already is that login.
    ///
    /// A recovered pane spawns a fresh shell carrying the account it was
    /// SPAWNED with, so an agent that was running under another login — an
    /// account from `zetty run`, or the default one in a pane spawned on an
    /// account — would otherwise come back under the spawn login, and look for
    /// its conversation in the wrong config dir. An account removed since the
    /// power-off falls through to nil, never strands the resume.
    public static func pinnedLogin(for entry: Entry, spawnedAccountID: String?,
                                   accounts: [AgentAccount], home: String) -> PinnedLogin? {
        guard let agent = entry.agent, let running = entry.agentAccount else { return nil }
        let login = AgentAccountResolver.resumeLogin(
            agentID: agent.rawValue, runningAccountID: running,
            spawnedAccountID: spawnedAccountID, accounts: accounts, home: home)
        return login == .inherited ? nil : PinnedLogin(accountID: running, login: login)
    }

    /// The line typed into a recovered pane to pick the harness session back
    /// up. `cd` first because Claude resolves `--resume` against the project
    /// the session belongs to and the pane's own shell may spawn elsewhere.
    ///
    /// nil for agents without a verified resume grammar, and for an id that
    /// fails `AgentEvent.isValidSessionID` (defence in depth — the hook parser
    /// already dropped those).
    ///
    /// `environment` is prefixed onto the harness alone (`KEY='v' claude …`),
    /// for a harness the pane's shell would otherwise start under the wrong
    /// login — see `AgentAccountResolver.resumeLogin`. A pair that is not a
    /// plain shell name and a safe value is dropped rather than typed.
    ///
    /// `unsetting` removes variables for the harness alone (`env -u KEY claude
    /// …`): the default login is the variable being ABSENT, and an empty
    /// assignment is not that — Codex refuses a `CODEX_HOME` naming no
    /// directory. `env` is what makes it one line in any shell.
    public static func resumeCommand(agent: AgentKind, sessionID: String, cwd: String,
                                     environment: [String: String] = [:],
                                     unsetting: [String] = []) -> String? {
        guard AgentEvent.isValidSessionID(sessionID) else { return nil }
        let quotedID = ShellQuote.singleQuoted(sessionID)
        let resume: String
        switch agent {
        case .claude: resume = "\(command(forCatalogID: "claude")) --resume \(quotedID)"
        case .codex:  resume = "\(command(forCatalogID: "codex")) resume \(quotedID)"
        default:      return nil
        }
        let assignments = EnvDirective.sanitized(environment)
            .filter { isShellName($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(ShellQuote.singleQuoted($0.value)) " }
            .joined()
        let removals = Set(unsetting).filter(isShellName).sorted().map { "-u \($0) " }.joined()
        let unset = removals.isEmpty ? "" : "env \(removals)"
        return "cd \(ShellQuote.singleQuoted(cwd)) && \(assignments)\(unset)\(resume)"
    }

    /// A name a POSIX shell accepts on the left of a prefix assignment.
    /// Anything else would be run as a COMMAND rather than assigned.
    private static func isShellName(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
        else { return false }
        return key.unicodeScalars.allSatisfy {
            $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0))
        }
    }

    private static func command(forCatalogID id: String) -> String {
        SpawnableAgent.catalog.first { $0.id == id }?.defaultCommand ?? id
    }
}
