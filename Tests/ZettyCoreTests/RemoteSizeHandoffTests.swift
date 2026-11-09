import Foundation
import Testing
@testable import ZettyCore

private let claim = TerminalFrame.data(Data(RemoteSizeHandoff.claim.utf8))
private let marker = Data(RemoteSizeHandoff.focusMarker.utf8)
private let t0 = Date(timeIntervalSince1970: 1_000)

@Test func focusMarkersAreStrippedFromInput() {
    let chunk = Data("ab".utf8) + marker + Data("c".utf8) + marker
    let split = RemoteSizeHandoff.splitFocus(chunk)
    #expect(split.input == Data("abc".utf8))
    #expect(split.focused)
    #expect(RemoteSizeHandoff.splitFocus(Data("x".utf8)) == (Data("x".utf8), false))
}

@Test func claimIsKeysZmxForwardsFromAnyClient() {
    // zmx 0.8.1 drops escapes and control keys from a client that didn't
    // type last; space and Backspace get through and switch the size.
    #expect(Array(RemoteSizeHandoff.claim.utf8) == [0x20, 0x7F])
}

@Test func firstAttachTakesTheSizeThenRepaints() {
    var driver = RelaySizeDriver()
    #expect(driver.attached(first: true, now: t0) == [claim])
    #expect(driver.drives)
    #expect(driver.due(now: t0.addingTimeInterval(0.1)) == [])
    #expect(driver.due(now: t0.addingTimeInterval(RemoteSizeHandoff.settle)) == [.repaint])
    #expect(driver.due(now: t0.addingTimeInterval(5)) == [])
}

@Test func reconnectWaitsForFocusOrAKey() {
    var driver = RelaySizeDriver()
    #expect(driver.attached(first: false, now: t0) == [])
    #expect(!driver.drives)
    #expect(driver.input(marker, now: t0) == [claim])
    #expect(driver.input(marker, now: t0) == [], "focus while driving sends nothing")
}

@Test func aKeyWhileAnotherScreenDrivesClaimsFirst() {
    var driver = RelaySizeDriver()
    _ = driver.attached(first: true, now: t0)
    #expect(driver.input(Data("a".utf8), now: t0) == [.data(Data("a".utf8))])
    driver.sizeMoved()
    let arrow = Data([0x1B, 0x5B, 0x42])
    #expect(driver.input(arrow, now: t0.addingTimeInterval(10)) == [claim, .data(arrow)])
    #expect(driver.due(now: t0.addingTimeInterval(10 + RemoteSizeHandoff.settle)) == [.repaint])
}
