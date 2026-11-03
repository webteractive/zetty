import Foundation
import Testing
@testable import ZettyCore

@Test func targetSplitsOnTheLastColon() {
    #expect(RemoteAttachTarget.parse("100.1.2.3:ab12cd34") == RemoteAttachTarget(host: "100.1.2.3", pane: "ab12cd34"))
    #expect(RemoteAttachTarget.parse("inggos-mac-mini:ab1") == RemoteAttachTarget(host: "inggos-mac-mini", pane: "ab1"))
    for bad in ["host:", "host:XYZ", "nocolon", ":ab12", "host:ab12cd34e"] {
        #expect(RemoteAttachTarget.parse(bad) == nil, "\(bad) should not parse")
    }
}

@Test func backoffGrowsAndCapsAtTenSeconds() {
    var policy = RelayPolicy(machine: "Mac mini")
    let steps = (0 ..< 6).map { _ in policy.next(.connectFailed) }
    #expect(steps.map(\.action) == [1, 2, 5, 10, 10, 10].map { .retry(after: $0, scrollback: true) })
    #expect(steps.map(\.message) == ["[can't reach Mac mini, retrying…]", nil, nil, nil, nil, nil])
}

@Test func firstAttemptAsksForScrollback() {
    var policy = RelayPolicy(machine: "m")
    #expect(policy.scrollback)
    #expect(policy.next(.connectFailed).action == .retry(after: 1, scrollback: true))
}

@Test func attachingResetsBackoffAndTurnsScrollbackOff() {
    var policy = RelayPolicy(machine: "Mac mini")
    _ = policy.next(.connectFailed)
    _ = policy.next(.connectFailed)
    #expect(policy.next(.attached) == (message: nil, action: .proceed))
    #expect(!policy.scrollback)
    let dropped = policy.next(.dropped)
    #expect(dropped.message == "[disconnected from Mac mini, reconnecting…]")
    #expect(dropped.action == .retry(after: 1, scrollback: false))
    // Still unreachable: no second message, the backoff carries on.
    let again = policy.next(.connectFailed)
    #expect(again.message == nil)
    #expect(again.action == .retry(after: 2, scrollback: false))
}

@Test func refusalStopsWithItsReason() {
    var policy = RelayPolicy(machine: "m")
    let step = policy.next(.refused("that pane is gone on Mac mini"))
    #expect(step.message == "[that pane is gone on Mac mini]")
    #expect(step.action == .stop)
}

@Test func versionMismatchStops() {
    var policy = RelayPolicy(machine: "Mac mini")
    let step = policy.next(.versionMismatch)
    #expect(step.message == "[Mac mini runs a different version of Zetty. Update both Macs.]")
    #expect(step.action == .stop)
}

@Test func badTargetIsAUsageError() {
    #expect(ControlCLI.run(["attach", "nocolon"]) == 64)
}
