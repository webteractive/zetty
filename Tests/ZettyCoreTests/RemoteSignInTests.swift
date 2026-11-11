import Foundation
import Testing
@testable import ZettyCore

private let ink = "\u{1B}[30;107m"
private let reset = "\u{1B}[0m"

@Test func qrCodeDrawsTwoRowsPerLineDarkOnLight() {
    #expect(QRText.lines([[true, false], [false, true]], quiet: 0) == [ink + "▀▄" + reset])
    #expect(QRText.lines([[true, true], [true, false]], quiet: 0) == [ink + "█▀" + reset])
    // An odd last row pairs with a light one.
    #expect(QRText.lines([[true], [true], [true]], quiet: 0) == [ink + "█" + reset, ink + "▀" + reset])
}

@Test func qrCodeGetsALightBorderScannersNeed() {
    #expect(QRText.lines([[true]], quiet: 1) == [ink + " ▄ " + reset, ink + "   " + reset])
    #expect(QRText.lines([], quiet: 2).isEmpty)
}

@Test func signInRequestAndReportRoundTripTheWire() throws {
    let request = ControlRequest.remoteSignIn
    #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    for report in [
        RemoteSignInReport(state: .needsSignIn, url: "https://login.tailscale.com/a/x", qr: ["10", "01"]),
        RemoteSignInReport(state: .signedIn, account: "glen@example.com", device: "zetty-mini"),
        RemoteSignInReport(state: .needsApproval),
    ] {
        let data = try JSONEncoder().encode(ControlResponse.signIn(report))
        #expect(try JSONDecoder().decode(ControlResponse.self, from: data) == .signIn(report))
    }
}

@Test func theReportsCodeComesBackAsModules() {
    let report = RemoteSignInReport(state: .needsSignIn, url: "https://login.tailscale.com/a/x", qr: ["10", "01"])
    #expect(report.modules == [[true, false], [false, true]])
    #expect(RemoteSignInReport(state: .needsApproval).modules == nil)
}

@Test func signInLinesGiveThePageAndTheCode() {
    let report = RemoteSignInReport(state: .needsSignIn, url: "https://login.tailscale.com/a/x", qr: ["1"])
    let lines = ControlCLI.signInLines(report, drawCode: true)
    #expect(lines.contains("https://login.tailscale.com/a/x"))
    #expect(lines.contains(ink + "  ▀  " + reset))
    #expect(lines.contains { $0.contains("scan the code with your phone") })
    #expect(lines.contains { $0.contains("don't share it") })
    #expect(lines.last == "For agents and scripts: zetty remote sign-in --json")

    // Piped, the code is left out: it is only for eyes.
    let plain = ControlCLI.signInLines(report, drawCode: false)
    #expect(!plain.contains { $0.contains(ink) })
    #expect(!plain.contains { $0.contains("scan") })
    #expect(plain.contains("https://login.tailscale.com/a/x"))
}

@Test func signInLinesSayWhenThereIsNothingToDo() {
    #expect(ControlCLI.signInLines(.init(state: .signedIn, account: "glen@example.com", device: "zetty-mini"),
                                   drawCode: true)
            == ["Already signed in to Tailscale as glen@example.com · zetty-mini."])
    #expect(ControlCLI.signInLines(.init(state: .signedIn, device: "zetty-mini"), drawCode: true)
            == ["Already signed in to Tailscale · zetty-mini."])
    #expect(ControlCLI.signInLines(.init(state: .needsApproval), drawCode: true)
            == ["Signed in. Waiting for your tailnet's admin to approve this Mac in Tailscale."])
}

@Test func theJSONLeavesOutTheCode() throws {
    let report = RemoteSignInReport(state: .needsSignIn, url: "https://login.tailscale.com/a/x", qr: ["1"])
    let json = try #require(ControlCLI.signInJSON(report))
    #expect(json.contains(#""state" : "needs-sign-in""#))
    #expect(json.contains(#""url" : "https://login.tailscale.com/a/x""#))
    #expect(!json.contains("qr"))
}

private let runningStatus = TailscaleStatus(backend: .running, me: nil, peers: [])

/// What the watch says for each state in turn.
private func noticed(_ states: [TailnetState]) -> [Bool] {
    var watch = TailnetSignInWatch()
    return states.map { watch.note($0) }
}

@Test func aFinishedSignInIsNoticedOnce() {
    #expect(noticed([.needsLogin(nil), .starting, .running(runningStatus), .running(runningStatus)])
            == [false, false, true, false])
}

@Test func aNormalStartIsNotASignIn() {
    #expect(noticed([.starting, .running(runningStatus)]) == [false, false])
    // Turned off while waiting: the next start isn't a sign-in either.
    #expect(noticed([.needsLogin(nil), .off, .running(runningStatus)]) == [false, false, false])
}
