import Testing
import Foundation
@testable import ZettyCore

private func decide(idle: TimeInterval, after: TimeInterval = 600, busy: Bool = false,
                    active: Bool = false, hib: Bool = false, off: Bool = false,
                    home: Bool = false) -> Bool {
    HibernationPolicy.shouldHibernate(idleFor: idle, hibernateAfter: after, isBusy: busy,
                                      isActive: active, isHibernated: hib, autoDisabled: off,
                                      isHome: home)
}

@Test func hibernatesWhenIdleAndQuiet() { #expect(decide(idle: 700)) }
@Test func notBeforeIdleThreshold()     { #expect(!decide(idle: 300)) }
@Test func neverWhenDisabled()          { #expect(!decide(idle: 9999, after: 0)) }
@Test func neverWhenActive()            { #expect(!decide(idle: 9999, active: true)) }
@Test func neverWhenBusy()              { #expect(!decide(idle: 9999, busy: true)) }
@Test func neverWhenAlreadyHibernated() { #expect(!decide(idle: 9999, hib: true)) }
@Test func neverWhenOptedOut()          { #expect(!decide(idle: 9999, off: true)) }
// The UI offers no hibernate verb for Home, so a timer that hibernated it
// would leave a state with no way back.
@Test func neverHibernatesHome()        { #expect(!decide(idle: 9999, home: true)) }
