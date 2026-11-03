import Foundation

/// Another Mac's Zetty as this one mirrors it. Owned by the connection that
/// feeds it; never written into the local workspace.
public struct RemoteMachine: Codable, Equatable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        case connecting
        case online
        case offline
        /// It answered on another protocol version.
        case needsUpdate(theirs: Int)
        /// It can't join, in plain words (see `PeerAdmission.Refusal.message`).
        case refused(String)
    }

    /// Tailscale's stable node ID: survives renames and address changes.
    public let stableID: String
    /// The hello's machine name once known, else Tailscale's host name.
    public var name: String
    public var state: State
    /// When a snapshot last arrived, or Tailscale's LastSeen if never connected.
    public var lastSeen: Date?
    public var workspace: StatusSnapshot?

    public init(stableID: String, name: String, state: State, lastSeen: Date?, workspace: StatusSnapshot?) {
        self.stableID = stableID
        self.name = name
        self.state = state
        self.lastSeen = lastSeen
        self.workspace = workspace
    }

    /// Panes on that Mac whose agent is waiting on the user.
    public var needsYouCount: Int {
        (workspace?.panes ?? []).filter { $0.agentStatus == AgentStatus.needsAttention.rawValue }.count
    }
}

/// The text on a machine's sidebar header: "2 · 1 needs you", "offline · seen 2h ago".
public enum RemoteMachineSummary {
    public static func text(for machine: RemoteMachine, now: Date) -> String {
        switch machine.state {
        case .connecting:
            return "connecting…"
        case .needsUpdate:
            return "needs update"
        case .refused(let reason):
            return reason
        case .offline:
            guard let seen = machine.lastSeen else { return "offline" }
            return "offline · seen \(ago(from: seen, to: now))"
        case .online:
            let awake = (machine.workspace?.projects ?? []).filter { !$0.hibernated }.count
            let waiting = machine.needsYouCount
            return waiting > 0 ? "\(awake) · \(waiting) needs you" : "\(awake)"
        }
    }

    private static func ago(from seen: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(seen))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}

/// The last known state of every remote machine, so an offline Mac still shows
/// its projects. Lives at `~/.zetty/remote-machines.json` in the app.
public struct RemoteMachineCache {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Everything loads as offline: a cached Mac hasn't been reached yet.
    public func load() -> [RemoteMachine] {
        guard let data = try? Data(contentsOf: url),
              let machines = try? JSONDecoder.cache.decode([RemoteMachine].self, from: data) else { return [] }
        return machines.map { var m = $0; m.state = .offline; return m }
    }

    public func save(_ machines: [RemoteMachine]) {
        guard let data = try? JSONEncoder.cache.encode(machines) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static var cache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var cache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
