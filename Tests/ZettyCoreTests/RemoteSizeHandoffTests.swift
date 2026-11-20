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
    driver.output(now: t0.addingTimeInterval(0.1))
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
    driver.output(now: t0.addingTimeInterval(10.1))
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

@Test func quietBeforeAnyAnswerIsNotARedrawDone() {
    // The serving Mac's attach can still be starting when the settle ends: no
    // output yet means zmx hasn't answered, not that the program redrew. A
    // repaint then restarted that attach and threw away the claim still
    // waiting in its pty, so the size stayed the other Mac's and only keys
    // brought it back (Glen, laptop opening a mini pane, 2026-11-17).
    var driver = RelaySizeDriver()
    driver.output(now: t0.addingTimeInterval(-1))
    _ = driver.attached(first: true, now: t0)
    #expect(driver.due(now: t0.addingTimeInterval(RemoteSizeHandoff.settle)) == [])
    #expect(driver.due(now: t0.addingTimeInterval(1)) == [])
}

@Test func aRepaintThatNeverHeardBackClaimsAgain() {
    // At the limit the repaint goes ahead, and the claim follows it into the
    // new attach, in case the first one went with the old.
    var driver = RelaySizeDriver()
    _ = driver.attached(first: true, now: t0)
    #expect(driver.due(now: t0.addingTimeInterval(RemoteSizeHandoff.settleLimit)) == [.repaint, claim])
    #expect(driver.drives)
}

@Test func onlyTheZettyInUseClaimsOnHover() {
    // Screen Sharing in front on the laptop: its Zetty still gets the
    // pointer's moves, and claiming then flips the pane between the Macs.
    #expect(RemoteSizeHandoff.pointerClaims(appActive: true, windowKey: true))
    #expect(!RemoteSizeHandoff.pointerClaims(appActive: false, windowKey: true))
    #expect(!RemoteSizeHandoff.pointerClaims(appActive: true, windowKey: false))
}

// MARK: - The serving Mac's attach marker

@Test func attachMarkersAreStrippedFromOutput() {
    var chunk = Data("SCREEN".utf8)
    chunk.append(Data(RemoteSizeHandoff.attachMarker.utf8))
    chunk.append(Data("live".utf8))
    let split = RemoteSizeHandoff.splitAttach(chunk)
    #expect(split.output == Data("SCREENlive".utf8))
    #expect(split.started)
    let plain = RemoteSizeHandoff.splitAttach(Data("plain".utf8))
    #expect(plain.output == Data("plain".utf8))
    #expect(!plain.started)
}

/// A first open over a slow path: the serving Mac is still printing the
/// scrollback replay at the limit, with the claim unread in its pty. The
/// replay is not the program's answer, so nothing repaints until the attach
/// has started and the program has redrawn (release review, 2026-11-20).
@Test func aReplayStillArrivingIsNotTheProgramsAnswer() {
    var driver = RelaySizeDriver()
    driver.expectsAttachMarker = true
    #expect(driver.attached(first: true, now: t0) == [.data(Data(RemoteSizeHandoff.claim.utf8))])
    var at = 0.0
    while at < 5 {
        driver.output(now: t0.addingTimeInterval(at))
        #expect(driver.due(now: t0.addingTimeInterval(at)) == [], "at \(at)")
        at += 0.1
    }
    driver.attachStarted(now: t0.addingTimeInterval(5))
    driver.output(now: t0.addingTimeInterval(5.1))
    #expect(driver.due(now: t0.addingTimeInterval(5.2)) == [])
    // The attach read the claim when it started, so the repaint needs no
    // second one.
    #expect(driver.due(now: t0.addingTimeInterval(5.5)) == [.repaint])
}

@Test func aRepaintWaitsForItsOwnAttachBeforeTheNextClaimSettles() {
    var driver = RelaySizeDriver()
    driver.expectsAttachMarker = true
    _ = driver.attached(first: true, now: t0)
    driver.attachStarted(now: t0.addingTimeInterval(0.1))
    driver.output(now: t0.addingTimeInterval(0.2))
    #expect(driver.due(now: t0.addingTimeInterval(0.6)) == [.repaint])
    // The other Mac types, then this one does, while the repaint's attach
    // is still replaying.
    driver.sizeMoved()
    _ = driver.input(Data("a".utf8), now: t0.addingTimeInterval(1))
    driver.output(now: t0.addingTimeInterval(1.1))
    #expect(driver.due(now: t0.addingTimeInterval(4)) == [])
    driver.attachStarted(now: t0.addingTimeInterval(4))
    driver.output(now: t0.addingTimeInterval(4.1))
    #expect(driver.due(now: t0.addingTimeInterval(4.5)) == [.repaint])
}

@Test func aMarkerThatNeverComesFallsBackAfterTheAttachLimit() {
    var driver = RelaySizeDriver()
    driver.expectsAttachMarker = true
    _ = driver.attached(first: true, now: t0)
    let limit = RemoteSizeHandoff.attachLimit
    #expect(driver.due(now: t0.addingTimeInterval(limit - 0.1)) == [])
    #expect(driver.due(now: t0.addingTimeInterval(limit))
        == [.repaint, .data(Data(RemoteSizeHandoff.claim.utf8))])
}

/// Against a serving Mac with no attach marker, the claim a repaint sends
/// again gets no repaint of its own: that repaint's replay is still
/// arriving when one would fire, and it would kill the attach with the
/// claim unread, leaving the size on the other Mac until a key (review of
/// 70c34a5, 2026-11-20). With the marker this can't arise: the claim is read
/// as the attach starts, and the one repaint follows the redraw.
@Test func aSecondClaimToAnUnmarkedServerGetsNoRepaintOfItsOwn() {
    var driver = RelaySizeDriver()
    _ = driver.attached(first: true, now: t0)
    let limit = RemoteSizeHandoff.settleLimit
    #expect(driver.due(now: t0.addingTimeInterval(limit)) == [.repaint, claim])
    driver.output(now: t0.addingTimeInterval(limit + 0.1))
    #expect(driver.due(now: t0.addingTimeInterval(limit + 0.6)) == [])
    #expect(driver.due(now: t0.addingTimeInterval(4 * limit)) == [])
}

/// The marker can arrive in the same read as the server's `attached`, and
/// those bytes are delivered before the driver hears of the attach. It still
/// counts: a reset in `attached` made that first repaint wait out the 10 s
/// limit (review of 70c34a5, 2026-11-20).
@Test func aMarkerInTheFirstBytesStillCounts() {
    var driver = RelaySizeDriver()
    driver.expectsAttachMarker = true
    driver.connectionStarted()
    driver.attachStarted(now: t0)
    _ = driver.attached(first: true, now: t0.addingTimeInterval(0.01))
    driver.output(now: t0.addingTimeInterval(0.1))
    #expect(driver.due(now: t0.addingTimeInterval(0.6)) == [.repaint])
}
