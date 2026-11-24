import Foundation

/// Tells a quiet workspace feed from a dead one.
///
/// A feed carries only the serving Mac's frames, and the dialled side of a
/// link has no keepalive (gVisor's outgoing conns expose none). So a link
/// that outlived the serving Mac (a quit and relaunch, a sleep) read as an
/// idle Mac: "online", with its last snapshot, indefinitely. A serving Mac
/// that offers `RemoteFeature.feedHeartbeat` re-sends its latest snapshot
/// after `resendInterval` of quiet, so its viewer drops the link once nothing
/// has arrived for `silenceLimit` and dials again.
public struct FeedLiveness {
    public static let resendInterval: TimeInterval = 15
    /// Room for two resends to go missing before the link is dropped.
    public static let silenceLimit: TimeInterval = 45

    /// False for an older serving Mac: it sends nothing while its workspace
    /// is unchanged, so its silence proves nothing.
    private let watched: Bool
    private var lastHeard: Date

    public init(serverHello: RemoteHello, at now: Date) {
        watched = serverHello.offers(RemoteFeature.feedHeartbeat)
        lastHeard = now
    }

    /// A frame arrived.
    public mutating func heard(at now: Date) {
        lastHeard = now
    }

    public func isDead(at now: Date) -> Bool {
        watched && now.timeIntervalSince(lastHeard) > Self.silenceLimit
    }

    /// The serving side: a feed that has sent nothing for `resendInterval`
    /// gets the latest snapshot again.
    public static func resendIsDue(lastSent: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastSent) >= resendInterval
    }
}
