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

@Test func aRedrawStillStreamingPutsOffTheRepaint() {
    // Claude Code on a long conversation is still redrawing at the new size
    // when the settle ends; a repaint then copies a half-drawn screen.
    var driver = RelaySizeDriver()
    _ = driver.attached(first: true, now: t0)
    driver.output(now: t0.addingTimeInterval(0.30))
    driver.output(now: t0.addingTimeInterval(0.45))
    #expect(driver.due(now: t0.addingTimeInterval(0.50)) == [])
    #expect(driver.due(now: t0.addingTimeInterval(0.45 + RemoteSizeHandoff.quiet)) == [.repaint])
}

@Test func theRepaintWaitsNoLongerThanTheLimit() {
    var driver = RelaySizeDriver()
    _ = driver.attached(first: true, now: t0)
    var at = 0.0
    while at < RemoteSizeHandoff.settleLimit {
        driver.output(now: t0.addingTimeInterval(at))
        #expect(driver.due(now: t0.addingTimeInterval(at)) == [], "at \(at)")
        at += 0.1
    }
    driver.output(now: t0.addingTimeInterval(RemoteSizeHandoff.settleLimit))
    #expect(driver.due(now: t0.addingTimeInterval(RemoteSizeHandoff.settleLimit)) == [.repaint])
}

@Test func onlyTheZettyInUseClaimsOnHover() {
    // Screen Sharing in front on the laptop: its Zetty still gets the
    // pointer's moves, and claiming then flips the pane between the Macs.
    #expect(RemoteSizeHandoff.pointerClaims(appActive: true, windowKey: true))
    #expect(!RemoteSizeHandoff.pointerClaims(appActive: false, windowKey: true))
    #expect(!RemoteSizeHandoff.pointerClaims(appActive: true, windowKey: false))
}
