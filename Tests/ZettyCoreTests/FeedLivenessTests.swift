import Foundation
import Testing
@testable import ZettyCore

private let start = Date(timeIntervalSince1970: 1_000_000)

private func hello(features: [String]?) -> RemoteHello {
    RemoteHello(machine: "Mac mini", zettyVersion: "0.1.64", protocolVersion: RemoteProtocol.version,
                features: features)
}

/// A viewer's link outlived a restart of the serving Mac: a feed only carries
/// the server's frames and the dialled side has no keepalive, so the laptop
/// kept the mini "online" with a two-day-old snapshot (2026-11-24). A serving
/// Mac now says it re-sends while idle, so silence means the link is gone.
@Test func aServingMacOffersTheFeedHeartbeat() {
    #expect(RemoteFeature.all.contains(RemoteFeature.feedHeartbeat))
}

@Test func aHeartbeatFeedSilentPastTheLimitIsDead() {
    let feed = FeedLiveness(serverHello: hello(features: [RemoteFeature.feedHeartbeat]), at: start)
    #expect(!feed.isDead(at: start.addingTimeInterval(FeedLiveness.silenceLimit)))
    #expect(feed.isDead(at: start.addingTimeInterval(FeedLiveness.silenceLimit + 1)))
}

@Test func aHeartbeatFeedThatKeepsHearingStaysAlive() {
    var feed = FeedLiveness(serverHello: hello(features: [RemoteFeature.feedHeartbeat]), at: start)
    let later = start.addingTimeInterval(FeedLiveness.silenceLimit)
    feed.heard(at: later)
    #expect(!feed.isDead(at: later.addingTimeInterval(FeedLiveness.silenceLimit)))
    #expect(feed.isDead(at: later.addingTimeInterval(FeedLiveness.silenceLimit + 1)))
}

/// An older serving Mac sends nothing while its workspace is unchanged, so
/// its silence proves nothing: dropping it would reconnect every minute.
@Test func aFeedFromAServerWithoutTheHeartbeatIsNeverCalledDead() {
    let old = FeedLiveness(serverHello: hello(features: nil), at: start)
    #expect(!old.isDead(at: start.addingTimeInterval(86_400)))
    let markerOnly = FeedLiveness(serverHello: hello(features: [RemoteFeature.attachMarker]), at: start)
    #expect(!markerOnly.isDead(at: start.addingTimeInterval(86_400)))
}

/// The limit leaves room for two resends to go missing before a drop.
@Test func theSilenceLimitCoversMoreThanTwoResends() {
    #expect(FeedLiveness.silenceLimit > 2 * FeedLiveness.resendInterval)
}

@Test func aResendIsDueOnlyAfterTheIntervalOfQuiet() {
    #expect(!FeedLiveness.resendIsDue(lastSent: start, now: start.addingTimeInterval(FeedLiveness.resendInterval - 1)))
    #expect(FeedLiveness.resendIsDue(lastSent: start, now: start.addingTimeInterval(FeedLiveness.resendInterval)))
}
