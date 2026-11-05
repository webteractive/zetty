import Foundation

/// One machine on the tailnet, as `tailscale status --json` or
/// `tailscale whois --json` describes it.
public struct TailscaleNode: Equatable, Sendable {
    /// The node's stable ID (`ID` in status, `Node.StableID` in whois).
    public let stableID: String
    public let hostName: String
    /// MagicDNS name without the trailing dot.
    public let dnsName: String
    /// `macOS`, `iOS`, `linux`, … exactly as Tailscale reports it.
    public let os: String
    public let userID: Int64
    public let tags: [String]
    /// Bare IPs: whois's `/32` and `/128` prefix lengths are stripped.
    public let addresses: [String]
    public let online: Bool
    /// When Tailscale last saw it; nil for Go's zero time, which means never.
    public let lastSeen: Date?

    public init(stableID: String, hostName: String, dnsName: String, os: String, userID: Int64,
                tags: [String], addresses: [String], online: Bool, lastSeen: Date?) {
        self.stableID = stableID
        self.hostName = hostName
        self.dnsName = dnsName
        self.os = os
        self.userID = userID
        self.tags = tags
        self.addresses = addresses
        self.online = online
        self.lastSeen = lastSeen
    }
}

/// `tailscale status --json`, reduced to what Zetty needs.
public struct TailscaleStatus: Equatable, Sendable {
    public enum Backend: Equatable, Sendable { case running, stopped, needsLogin, other(String) }

    public let backend: Backend
    /// This Mac. Nil when Tailscale has no node for it: a stopped Tailscale
    /// still reports a `Self`, with an empty `ID`.
    public let me: TailscaleNode?
    /// Every other node, sorted by host name.
    public let peers: [TailscaleNode]

    public init(backend: Backend, me: TailscaleNode?, peers: [TailscaleNode]) {
        self.backend = backend
        self.me = me
        self.peers = peers
    }

    public static func parse(_ data: Data) -> TailscaleStatus? {
        guard let raw = try? JSONDecoder().decode(RawStatus.self, from: data) else { return nil }
        let backend: Backend = switch raw.BackendState ?? "" {
        case "Running": .running
        case "Stopped": .stopped
        case "NeedsLogin": .needsLogin
        case let other: .other(other)
        }
        let peers = (raw.Peer ?? [:]).values.compactMap { $0.node }
            .sorted { $0.hostName.localizedStandardCompare($1.hostName) == .orderedAscending }
        return TailscaleStatus(backend: backend, me: raw.Self?.node, peers: peers)
    }
}

/// `tailscale whois --json <ip>`.
public enum TailscaleWhois {
    public static func parse(_ data: Data) -> TailscaleNode? {
        guard let raw = try? JSONDecoder().decode(RawWhois.self, from: data),
              let node = raw.Node, let stableID = node.StableID, !stableID.isEmpty,
              let user = node.User else { return nil }
        return TailscaleNode(
            stableID: stableID,
            hostName: node.Hostinfo?.Hostname ?? node.Name.map(firstLabel) ?? "",
            dnsName: trimDot(node.Name ?? ""),
            os: node.Hostinfo?.OS ?? "",
            userID: user,
            tags: node.Tags ?? [],
            addresses: (node.Addresses ?? []).map { $0.split(separator: "/").first.map(String.init) ?? $0 },
            online: true,
            lastSeen: nil)
    }
}

// MARK: - Wire shapes (Tailscale's field names)

private struct RawStatus: Decodable {
    let BackendState: String?
    let `Self`: RawPeer?
    let Peer: [String: RawPeer]?
}

private struct RawPeer: Decodable {
    let ID: String?
    let HostName: String?
    let DNSName: String?
    let OS: String?
    let UserID: Int64?
    let Tags: [String]?
    let TailscaleIPs: [String]?
    let Online: Bool?
    let LastSeen: String?

    var node: TailscaleNode? {
        guard let ID, !ID.isEmpty else { return nil }
        return TailscaleNode(
            stableID: ID,
            hostName: HostName ?? "",
            dnsName: trimDot(DNSName ?? ""),
            os: OS ?? "",
            userID: UserID ?? 0,
            tags: Tags ?? [],
            addresses: TailscaleIPs ?? [],
            online: Online ?? false,
            lastSeen: LastSeen.flatMap(parseLastSeen))
    }
}

private struct RawWhois: Decodable {
    struct Node: Decodable {
        struct Hostinfo: Decodable { let OS: String?; let Hostname: String? }
        let StableID: String?
        let Name: String?
        let User: Int64?
        let Tags: [String]?
        let Addresses: [String]?
        let Hostinfo: Hostinfo?
    }
    let Node: Node?
}

private func trimDot(_ name: String) -> String {
    name.hasSuffix(".") ? String(name.dropLast()) : name
}

private func firstLabel(_ name: String) -> String {
    String(name.split(separator: ".").first ?? Substring(name))
}

/// Go's zero time (`0001-01-01T00:00:00Z`) means "never", not year one.
private func parseLastSeen(_ text: String) -> Date? {
    guard !text.hasPrefix("0001-") else { return nil }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}

/// The environment Zetty runs the `tailscale` CLI with.
public enum TailscaleCLIEnvironment {
    /// `environment` with `TERM` set when it has neither `TERM` nor
    /// `TERM_PROGRAM`. The binary inside Tailscale.app runs as the CLI only
    /// when it sees one of them; without both it tries to start the GUI and
    /// fails ("The Tailscale GUI failed to start", CLIError error 3). A Zetty
    /// opened from the Dock or Finder has neither, so every status check
    /// failed: it never served and never dialled another Mac.
    public static func prepare(_ environment: [String: String]) -> [String: String] {
        guard environment["TERM"] == nil, environment["TERM_PROGRAM"] == nil else { return environment }
        var environment = environment
        environment["TERM"] = "dumb"
        return environment
    }
}
