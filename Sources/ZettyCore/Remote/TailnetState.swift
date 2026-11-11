import Foundation

/// What Zetty's own Tailscale node is doing, in the terms Settings, the
/// notifications and the remote features need.
public enum TailnetState: Equatable, Sendable {
    /// Not running: both remote switches are off, or it stopped.
    case off
    case starting
    /// Waiting for a sign-in in the browser. The URL is nil until Tailscale
    /// has made one (or when it wasn't a Tailscale login page).
    case needsLogin(URL?)
    /// Signed in, but the tailnet's admin must approve this device.
    case needsApproval
    case running(TailscaleStatus)
    case failed(String)

    /// The node's own status, when it has one.
    public var status: TailscaleStatus? {
        if case .running(let status) = self { return status }
        return nil
    }

    /// For Zetty's log: the state without the sign-in link (it would enroll
    /// this Zetty in whoever's tailnet opens it).
    public var logDescription: String {
        switch self {
        case .off: "off"
        case .starting: "starting"
        case .needsLogin(let url): url == nil ? "needs sign-in" : "needs sign-in (page ready)"
        case .needsApproval: "needs admin approval"
        case .running(let status): "running as \(status.me?.hostName ?? "?"), \(status.peers.count) peers"
        case .failed(let message): "failed: \(message)"
        }
    }

    /// A state event from the bridge (`{"state","authURL","error"}`) read
    /// with the node's latest status.
    public static func from(event: Data, status: TailscaleStatus?) -> TailnetState {
        // A node that reads Running with a node of its own is running,
        // whatever one-off error an earlier event carried.
        if let status, status.backend == .running, status.me != nil { return .running(status) }
        guard let raw = try? JSONDecoder().decode(RawEvent.self, from: event) else { return .starting }
        if let error = raw.error, !error.isEmpty { return .failed(error) }
        switch raw.state ?? "" {
        case "NeedsLogin": return .needsLogin(raw.authURL.flatMap(loginURL))
        case "NeedsMachineAuth": return .needsApproval
        case "Running":
            if let status, status.me != nil { return .running(status) }
            return .starting
        case "Stopped": return .off
        default: return .starting
        }
    }

    /// The sign-in page Tailscale asks to open now (`"browse":true`, sent
    /// after a sign-in request), or nil. The URL an ordinary state event
    /// carries may be days old and expired, so Sign In never opens that one.
    public static func pageToOpen(event: Data) -> URL? {
        guard let raw = try? JSONDecoder().decode(RawEvent.self, from: event), raw.browse == true else { return nil }
        return raw.authURL.flatMap(loginURL)
    }

    /// Only an https page on Tailscale's own site is ever opened.
    public static func loginURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              host == "tailscale.com" || host.hasSuffix(".tailscale.com") else { return nil }
        return url
    }

    private struct RawEvent: Decodable {
        let state: String?
        let authURL: String?
        let error: String?
        let browse: Bool?
    }
}

/// Notices the moment a sign-in finishes: running after waiting for one,
/// even with a connecting step between. A normal start (no sign-in asked)
/// isn't one, and turning off or failing forgets the wait.
public struct TailnetSignInWatch: Sendable {
    private var waiting = false

    public init() {}

    /// True once, when `state` is the running that a sign-in led to.
    public mutating func note(_ state: TailnetState) -> Bool {
        switch state {
        case .needsLogin: waiting = true
        case .running:
            defer { waiting = false }
            return waiting
        case .off, .failed: waiting = false
        case .starting, .needsApproval: break
        }
        return false
    }
}
