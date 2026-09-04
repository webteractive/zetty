import Foundation

/// A lifecycle event reported by an agent's harness hook (Claude Code, Codex, …).
///
/// The hook forwards a small JSON object per line to Zetty's event sink; each
/// line parses into one `AgentEvent`. Correlation back to a pane is by
/// `surface` when the hook ran in a Zetty pane that injected one, else by
/// `cwd` (the working directory the harness passes).
public struct AgentEvent: Equatable, Sendable {

    /// Lifecycle transitions a hook can report. `ended` clears presence (the
    /// agent exited); the rest map onto `HookEvent` status.
    public enum Kind: String, Sendable, Equatable {
        case running
        case idle
        case needsAttention
        case ended
    }

    public let cwd: String
    public let agent: AgentKind
    public let event: Kind
    /// The pane the hook ran in (from `ZETTY_SURFACE`, or the `ZETTY_CWD_FILE`
    /// stem). nil for a hook helper older than this field; the receiver then
    /// falls back to cwd matching.
    public let surface: UUID?
    /// The harness's own session id (Claude `session_id`, Codex `thread-id`),
    /// validated by `isValidSessionID` so it can be typed into a shell later.
    public let session: String?

    public init(cwd: String, agent: AgentKind, event: Kind, surface: UUID? = nil, session: String? = nil) {
        self.cwd = cwd
        self.agent = agent
        self.event = event
        self.surface = surface
        self.session = session
    }

    /// `[A-Za-z0-9._-]{1,128}` — everything Claude and Codex emit, nothing a
    /// shell could interpret.
    public static func isValidSessionID(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 128 else { return false }
        return raw.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": return true
            default: return false
            }
        }
    }

    /// The `HookEvent` this maps to, or `nil` for `.ended` (which clears presence).
    public var hookEvent: HookEvent? {
        switch event {
        case .running:        return .running
        case .idle:           return .idle
        case .needsAttention: return .needsAttention
        case .ended:          return nil
        }
    }

    /// Parses one JSON line:
    /// `{"cwd": "...", "agent": "claude", "event": "running", "surface": "<uuid>", "session": "<id>"}`.
    /// Returns nil for malformed input, an unknown agent, or an unknown event.
    /// `surface` and `session` are OPTIONAL — a helper predating them, or a
    /// value that fails validation, yields nil for that field without
    /// rejecting the line.
    /// `agent` matches an `AgentKind` raw value or any of its registry `binaryNames`;
    /// `event` accepts a few friendly aliases.
    public static func parse(line: String) -> AgentEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let cwd = (object["cwd"] as? String)?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty,
              let agentRaw = object["agent"] as? String,
              let eventRaw = object["event"] as? String
        else { return nil }

        guard let agent = resolveAgent(agentRaw), let kind = resolveEvent(eventRaw) else { return nil }
        let surface = (object["surface"] as? String).flatMap(UUID.init(uuidString:))
        let session = (object["session"] as? String).flatMap { isValidSessionID($0) ? $0 : nil }
        return AgentEvent(cwd: cwd, agent: agent, event: kind, surface: surface, session: session)
    }

    private static func resolveAgent(_ raw: String) -> AgentKind? {
        if let kind = AgentKind(rawValue: raw.lowercased()) { return kind }
        return AgentRegistry.match(command: raw)?.kind
    }

    private static func resolveEvent(_ raw: String) -> Kind? {
        switch raw.lowercased() {
        case "running", "active", "busy", "start", "pretooluse", "posttooluse", "userpromptsubmit":
            return .running
        case "idle", "stop", "done", "finished":
            return .idle
        case "needsattention", "needs_attention", "attention", "notification", "waiting", "approval":
            return .needsAttention
        case "ended", "end", "exit", "sessionend":
            return .ended
        default:
            return nil
        }
    }
}
