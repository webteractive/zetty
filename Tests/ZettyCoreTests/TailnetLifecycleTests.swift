import Testing
@testable import ZettyCore

private extension TailnetLifecycle {
    mutating func start(_ name: String = "zetty-mini") -> Bool { requestStart(hostname: name) }
    mutating func stop() -> Bool { requestStop() }
}

@Test func aDeniedKeychainIsNotAskedAgainOnEveryReload() {
    var life = TailnetLifecycle()
    let first = life.start()
    life.startFailed(keychain: true)
    // Config reloads call start again: no new Keychain read, so no new prompt.
    let reload1 = life.start()
    let reload2 = life.start()
    // Turning Other Macs off and on is the user's retry.
    let stopped = life.stop()
    let retry = life.start()
    #expect(first && !reload1 && !reload2 && !stopped && retry)
}

@Test func otherStartFailuresRetryOnTheNextReload() {
    var life = TailnetLifecycle()
    _ = life.start()
    life.startFailed(keychain: false)
    let again = life.start()
    #expect(again)
}

@Test func aRunningNodeIsNotStartedTwiceAndStopsOnce() {
    var life = TailnetLifecycle()
    _ = life.start()
    life.started()
    let twice = life.start()
    let stop1 = life.stop()
    let stop2 = life.stop()
    #expect(!twice && stop1 && !stop2)
}

@Test func signOutLogsOutARunningNode() {
    var life = TailnetLifecycle()
    _ = life.start()
    life.started()
    let action = life.signOut()
    #expect(action == .logOut)
}

@Test func signOutWhileStuckForgetsTheSavedSignInAndStartsOver() {
    // An unreadable Keychain item: Sign Out is the way to start fresh.
    var life = TailnetLifecycle()
    _ = life.start()
    life.startFailed(keychain: true)
    let action = life.signOut()
    let restart = life.start()
    #expect(action == .forgetAndRestart(hostname: "zetty-mini"))
    #expect(restart)
}

@Test func signOutWithOtherMacsOffDoesNothing() {
    var life = TailnetLifecycle()
    let never = life.signOut()
    _ = life.start()
    life.started()
    _ = life.stop()
    let afterStop = life.signOut()
    #expect(never == .nothing && afterStop == .nothing)
}

@Test func aRenameWhileNotRunningIsWhatTheNextStartUses() {
    // Keychain refused, the device renamed in Settings, then Sign Out: the
    // restart used the old name (bug hunt, 2026-11-13).
    var lifecycle = TailnetLifecycle()
    _ = lifecycle.requestStart(hostname: "zetty-old")
    lifecycle.startFailed(keychain: true)
    lifecycle.rename(to: "zetty-new")
    #expect(lifecycle.signOut() == .forgetAndRestart(hostname: "zetty-new"))
}
