import Foundation

/// One pane's snapshot from the Claude Code mod (`Mods/zetty-bridge`), which
/// rewrites `~/.zetty/agent-usage/<surface>.json` whole on every change.
///
/// The classic hooks stay the only source of running / idle / needs-attention.
/// This ADDS what they cannot see: context fill, cost, rate limits, and why
/// the last turn ended.
public struct AgentUsage: Equatable, Sendable {

    /// The contract version this build reads. A file carrying another is
    /// ignored rather than guessed at.
    public static let supportedVersion = 1

    public enum TurnState: String, Sendable, Equatable {
        case running
        case idle
        /// The session is over; nothing about it is worth showing.
        case ended
    }

    public struct RateLimit: Equatable, Sendable {
        /// `five_hour`, `seven_day`, or a gateway's `spend_limit`.
        public let kind: String
        public let percentUsed: Double
        public let resetsAt: Date?

        public init(kind: String, percentUsed: Double, resetsAt: Date? = nil) {
            self.kind = kind
            self.percentUsed = percentUsed
            self.resetsAt = resetsAt
        }
    }

    /// What a needs-attention is waiting on, in the harness's own words.
    public struct Attention: Equatable, Sendable {
        public let message: String
        /// The harness's `notification_type`, e.g. `permission_prompt`.
        public let type: String?

        public init(message: String, type: String? = nil) {
            self.message = message
            self.type = type
        }
    }

    public let surface: UUID
    public var session: String?
    /// The session's working directory as the harness reports it, which is
    /// where a resume has to run; the pane's shell may live elsewhere.
    public var cwd: String?
    public var model: String?
    /// The harness's config-dir variable as the mod saw it: "" is the default
    /// login, nil a snapshot that said nothing.
    public var configDirectory: String?
    public var turnState: TurnState
    /// Why the last turn ended (`answer`, `aborted`, `refusal`, `error`), or
    /// the session did.
    public var turnReason: String?
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// 0–100; nil before the first response of the live window.
    public var contextPercent: Int?
    public var costUSD: Double?
    public var rateLimits: [RateLimit]
    public var attention: Attention?
    /// Seconds since the epoch.
    public var updatedAt: TimeInterval

    public init(surface: UUID, session: String? = nil, cwd: String? = nil, model: String? = nil,
                configDirectory: String? = nil, turnState: TurnState = .idle,
                turnReason: String? = nil, contextTokens: Int? = nil,
                contextWindow: Int? = nil, contextPercent: Int? = nil,
                costUSD: Double? = nil, rateLimits: [RateLimit] = [],
                attention: Attention? = nil, updatedAt: TimeInterval = 0) {
        self.surface = surface
        self.session = session
        self.cwd = cwd
        self.model = model
        self.configDirectory = configDirectory
        self.turnState = turnState
        self.turnReason = turnReason
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPercent = contextPercent
        self.costUSD = costUSD
        self.rateLimits = rateLimits
        self.attention = attention
        self.updatedAt = updatedAt
    }

    /// Whether the last turn ended in a way the user did not ask for: an API
    /// error or a refusal. An interrupt (`aborted`) is the user's own doing,
    /// and a running turn has not ended at all.
    public var turnFailed: Bool {
        turnState == .idle && (turnReason == "error" || turnReason == "refusal")
    }

    /// `API error` / `refused`, for a notification; nil when the turn did not fail.
    public var failureDescription: String? {
        guard turnFailed else { return nil }
        return turnReason == "refusal" ? "refused" : "API error"
    }

    /// `<SURFACE-UUID>.json`, the name the mod writes.
    public static func fileName(for surface: UUID) -> String {
        "\(surface.uuidString).json"
    }

    /// The surface a snapshot file names, or nil for anything else in the
    /// directory.
    public static func surface(fromFileName name: String) -> UUID? {
        guard name.hasSuffix(".json") else { return nil }
        return UUID(uuidString: String(name.dropLast(5)))
    }

    /// Parses one snapshot file. Returns nil for malformed input — which
    /// includes a file caught mid-write, since the mod's write is not atomic —
    /// an unknown version, another agent, or a surface that is no UUID.
    public static func parse(data: Data) -> AgentUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == supportedVersion,
              object["agent"] as? String == AgentKind.claude.rawValue,
              let surface = (object["surface"] as? String).flatMap(UUID.init(uuidString:))
        else { return nil }

        let turn = object["turn"] as? [String: Any] ?? [:]
        let context = object["context"] as? [String: Any] ?? [:]
        let limits = (object["rateLimits"] as? [[String: Any]] ?? []).compactMap { raw -> RateLimit? in
            guard let kind = raw["kind"] as? String,
                  let used = (raw["percentUsed"] as? NSNumber)?.doubleValue else { return nil }
            return RateLimit(kind: kind, percentUsed: used,
                             resetsAt: (raw["resetsAt"] as? String).flatMap(parseDate))
        }
        let session = (object["session"] as? String)
            .flatMap { AgentEvent.isValidSessionID($0) ? $0 : nil }
        let attention = (object["attention"] as? [String: Any]).flatMap { raw -> Attention? in
            guard let message = (raw["message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
            // It goes into a notification and a tooltip: one line, bounded.
            let line = message.split(whereSeparator: \.isNewline).joined(separator: " ")
            return Attention(message: String(line.prefix(200)), type: raw["type"] as? String)
        }

        return AgentUsage(
            surface: surface,
            session: session,
            cwd: (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            model: object["model"] as? String,
            configDirectory: object["config"] as? String,
            turnState: (turn["state"] as? String).flatMap(TurnState.init(rawValue:)) ?? .idle,
            turnReason: turn["reason"] as? String,
            contextTokens: (context["tokens"] as? NSNumber)?.intValue,
            contextWindow: (context["window"] as? NSNumber)?.intValue,
            contextPercent: (context["percent"] as? NSNumber).map { min(max($0.intValue, 0), 100) },
            costUSD: (object["costUSD"] as? NSNumber)?.doubleValue,
            rateLimits: limits,
            attention: attention,
            updatedAt: ((object["updatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// Whether this snapshot may be shown for its pane.
    ///
    /// A snapshot outlives a Claude that was killed without a `session.end`,
    /// so the file alone is never the whole answer. `foreground` is the
    /// foreground-process probe's reading for the pane: nil when there is no
    /// probe (`preserve-sessions` off), which leaves the snapshot's own word.
    public func isShown(foreground: String?) -> Bool {
        guard turnState != .ended else { return false }
        guard let foreground else { return true }
        return foreground == AgentKind.claude.rawValue
    }

    /// The snapshot as a VIEW reads it. `updatedAt` moves on every write, and
    /// tokens and cost tick many times inside one percent — they are tooltip
    /// detail, picked up by whatever refresh comes next — so comparing whole
    /// values would wake the chrome several times a turn for nothing visible.
    var visible: AgentUsage {
        var copy = self
        copy.updatedAt = 0
        copy.contextTokens = nil
        copy.costUSD = nil
        copy.rateLimits = rateLimits.map {
            RateLimit(kind: $0.kind, percentUsed: $0.percentUsed.rounded(), resetsAt: $0.resetsAt)
        }
        return copy
    }
}

/// The latest snapshot per pane.
public struct AgentUsageStore: Sendable {

    private var usages: [UUID: AgentUsage] = [:]

    public init() {}

    public func usage(for surface: UUID) -> AgentUsage? { usages[surface] }

    public var surfaces: Set<UUID> { Set(usages.keys) }

    /// Stores the snapshot and answers whether anything a view shows changed —
    /// the only case worth a chrome refresh.
    @discardableResult
    public mutating func apply(_ usage: AgentUsage) -> Bool {
        let previous = usages[usage.surface]
        usages[usage.surface] = usage
        return previous?.visible != usage.visible
    }

    /// Forgets a pane. Answers whether it had a snapshot.
    @discardableResult
    public mutating func remove(_ surface: UUID) -> Bool {
        usages.removeValue(forKey: surface) != nil
    }
}
