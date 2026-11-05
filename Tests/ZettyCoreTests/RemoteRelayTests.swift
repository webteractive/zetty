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

@Test func relayOnlyDialsTailnetAddresses() {
    for ok in ["100.64.0.1", "100.112.139.61", "100.127.255.255", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::5", "127.0.0.1", "::1"] {
        #expect(TailnetAddress.isAllowed(ok), "\(ok) should be allowed")
    }
    for bad in ["100.63.255.255", "100.128.0.1", "8.8.8.8", "192.168.1.10", "fd7a:115c:a1e1::1", "2606:4700::1", "nonsense"] {
        #expect(!TailnetAddress.isAllowed(bad), "\(bad) should be refused")
    }
}

@Test func relayCommandOnlyCarriesAWellFormedTarget() {
    let zetty = "/Applications/zetty.app/Contents/MacOS/zetty"
    #expect(RemoteAttachTarget.relayCommand(executable: zetty, address: "100.64.0.5", pane: "ab12cd34")
            == "\(zetty) attach 100.64.0.5:ab12cd34")
    // Both halves come from the other Mac's feed, and the command runs
    // through a shell: anything but hex and a numeric tailnet address is refused.
    #expect(RemoteAttachTarget.relayCommand(executable: zetty, address: "100.64.0.5", pane: "ab;rm -rf ~") == nil)
    #expect(RemoteAttachTarget.relayCommand(executable: zetty, address: "100.64.0.5", pane: "$(id)") == nil)
    #expect(RemoteAttachTarget.relayCommand(executable: zetty, address: "100.64.0.5;id", pane: "ab12cd34") == nil)
    #expect(RemoteAttachTarget.relayCommand(executable: zetty, address: "8.8.8.8", pane: "ab12cd34") == nil)
    #expect(RemoteAttachTarget.relayCommand(executable: "/tmp/my app/zetty", address: "100.64.0.5", pane: "ab12cd34") == nil)
}

@Test func paneCommandNeverFallsBackToAShell() {
    let zetty = "/Applications/zetty.app/Contents/MacOS/zetty"
    #expect(RemoteAttachTarget.paneCommand(executable: zetty, address: "100.64.0.5", pane: "ab12cd34")
            == "\(zetty) attach 100.64.0.5:ab12cd34")
    // nil would leave ghostty to start this Mac's own login shell in the pane.
    #expect(RemoteAttachTarget.paneCommand(executable: zetty, address: "100.64.0.5", pane: "x;id") == "/usr/bin/false")
    #expect(RemoteAttachTarget.paneCommand(executable: zetty, address: "8.8.8.8", pane: "ab12cd34") == "/usr/bin/false")
}

/// Runs the serving side's attach script against a fake zmx that logs each
/// call, with `list` reporting the session only while `alive` is true.
private func runServedAttach(scrollback: Bool, alive: Bool) throws -> [String] {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("calls").path
    let zmx = dir.appendingPathComponent("zmx").path
    let listed = alive ? "printf 'name=zetty-ab12cd34\\tpid=1\\tclients=1\\n'" : ":"
    try """
    #!/bin/sh
    echo "$1" >> \(log)
    [ "$1" = list ] && { printf 'name=zetty-ab12cd3\\tpid=2\\n'; \(listed); }
    exit 0
    """.write(toFile: zmx, atomically: true, encoding: .utf8)
    chmod(zmx, 0o755)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = RemoteServedAttach.arguments(zmx: zmx, session: "zetty-ab12cd34", scrollback: scrollback)
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

@Test func servedAttachNeverCreatesAMissingSession() throws {
    #expect(try runServedAttach(scrollback: true, alive: true) == ["history", "list", "attach"])
    #expect(try runServedAttach(scrollback: false, alive: true) == ["list", "attach"])
    // Closed on this Mac during the replay: attach would start a new shell.
    #expect(try runServedAttach(scrollback: true, alive: false) == ["history", "list"])
    #expect(try runServedAttach(scrollback: false, alive: false) == ["list"])
}
