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

        public init(surface: UUID, snapshot: String?, agent: AgentKind?,
                    agentSession: String?, agentCwd: String?) {
            self.surface = surface
            self.snapshot = snapshot
            self.agent = agent
            self.agentSession = agentSession
            self.agentCwd = agentCwd
        }

        private enum CodingKeys: String, CodingKey { case surface, snapshot, agent, agentSession, agentCwd }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            surface = try c.decode(UUID.self, forKey: .surface)
            snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot)
            // An agent kind this build doesn't know decodes as "no agent"
            // rather than failing the whole file.
            agent = try c.decodeIfPresent(String.self, forKey: .agent).flatMap(AgentKind.init(rawValue:))
            agentSession = try c.decodeIfPresent(String.self, forKey: .agentSession)
            agentCwd = try c.decodeIfPresent(String.self, forKey: .agentCwd)
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
        public static func make(
            surfaces: [UUID],
            snapshots: [UUID: String],
            agentStates: [UUID: AgentState],
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
                    agentCwd: session?.cwd)
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

    /// The line typed into a recovered pane to pick the harness session back
    /// up. `cd` first because Claude resolves `--resume` against the project
    /// the session belongs to and the pane's own shell may spawn elsewhere.
    ///
    /// nil for agents without a verified resume grammar, and for an id that
    /// fails `AgentEvent.isValidSessionID` (defence in depth — the hook parser
    /// already dropped those).
    public static func resumeCommand(agent: AgentKind, sessionID: String, cwd: String) -> String? {
        guard AgentEvent.isValidSessionID(sessionID) else { return nil }
        let quotedID = ShellQuote.singleQuoted(sessionID)
        let resume: String
        switch agent {
        case .claude: resume = "\(command(forCatalogID: "claude")) --resume \(quotedID)"
        case .codex:  resume = "\(command(forCatalogID: "codex")) resume \(quotedID)"
        default:      return nil
        }
        return "cd \(ShellQuote.singleQuoted(cwd)) && \(resume)"
    }

    private static func command(forCatalogID id: String) -> String {
        SpawnableAgent.catalog.first { $0.id == id }?.defaultCommand ?? id
    }
}
