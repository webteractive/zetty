import Testing
import Foundation
@testable import ZettyCore

private let idA = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
private let idB = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

@Test func sessionNameIsStableShortHexOfUUID() {
    #expect(SessionPersistence.sessionName(for: idA) == "zetty-abcdef01")
    // Deterministic: same UUID → same name (relaunch reattaches).
    #expect(SessionPersistence.sessionName(for: idA) == SessionPersistence.sessionName(for: idA))
}

@Test func attachCommandUsesZmxPathAndName() {
    let cmd = SessionPersistence.attachCommand(zmxPath: "/opt/homebrew/bin/zmx", surfaceID: idA)
    // ZMX_SESSION must be stripped: if Zetty was launched from inside a
    // zmx-backed terminal (e.g. Supacode), an inherited ZMX_SESSION makes
    // `zmx attach` kill that session instead of attaching ours.
    #expect(cmd == "/usr/bin/env -u ZMX_SESSION /opt/homebrew/bin/zmx attach zetty-abcdef01")
}

@Test func attachCommandWithRestoreScriptWrapsAttach() {
    let cmd = SessionPersistence.attachCommand(
        zmxPath: "/opt/homebrew/bin/zmx",
        surfaceID: idA,
        restoreScriptPath: "/Users/g/.zetty/scrollback-restore.sh")
    // Plain space-separated tokens — ghostty's `command` parser can't be
    // relied on for quote grouping, so nothing here may need quoting.
    #expect(cmd == "/bin/sh /Users/g/.zetty/scrollback-restore.sh /opt/homebrew/bin/zmx zetty-abcdef01")
}

@Test func restoreScriptReplaysHistoryThenExecsAttach() {
    let script = SessionPersistence.restoreScriptContents
    #expect(script.hasPrefix("#!/bin/sh"))
    // ZMX_SESSION inherited from a zmx-backed terminal makes `zmx attach`
    // kill that session — the script must strip it for both invocations.
    #expect(script.contains("unset ZMX_SESSION"))
    let history = script.range(of: "\"$1\" history \"$2\" --vt 2>/dev/null")
    let attach = script.range(of: "exec \"$1\" attach \"$2\"")
    #expect(history != nil)
    #expect(attach != nil)
    if let history, let attach {
        #expect(history.lowerBound < attach.lowerBound)   // replay BEFORE attach
    }
}

@Test func restoreScriptInvokesHistoryThenAttachWithoutZmxSession() throws {
    // Behavioral check with a stub zmx: history first, then attach, both with
    // the session name, both with ZMX_SESSION stripped even when inherited.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-restore-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let scriptURL = dir.appendingPathComponent("scrollback-restore.sh")
    try SessionPersistence.restoreScriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)

    let logURL = dir.appendingPathComponent("calls.log")
    let stubURL = dir.appendingPathComponent("zmx")
    try """
    #!/bin/sh
    echo "$1 $2 ${ZMX_SESSION:-none}" >> "\(logURL.path)"
    """.write(to: stubURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubURL.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [scriptURL.path, stubURL.path, "zetty-test1234"]
    var env = ProcessInfo.processInfo.environment
    env["ZMX_SESSION"] = "inherited-parent-session"
    process.environment = env
    try process.run()
    process.waitUntilExit()

    let calls = try String(contentsOf: logURL, encoding: .utf8)
    #expect(calls == "history zetty-test1234 none\nattach zetty-test1234 none\n")
    #expect(process.terminationStatus == 0)
}

@Test func listParsingKeepsOnlyZettySessions() {
    let output = """
    zetty-abcdef01
    someone-elses-session
    zetty-11111111
    """
    #expect(SessionPersistence.zettySessions(fromList: output) == ["zetty-abcdef01", "zetty-11111111"])
}

@Test func orphanDiffingExcludesLiveSurfaces() {
    let existing = ["zetty-abcdef01", "zetty-11111111", "zetty-deadbeef"]
    let orphans = SessionPersistence.orphans(existing: existing, liveSurfaceIDs: [idA, idB])
    #expect(orphans == ["zetty-deadbeef"])
}

@Test func configParsesConfirmQuit() {
    #expect(AppConfig.parse("confirm-quit = false").confirmQuit == false)
    #expect(AppConfig.parse("confirm-quit = true").confirmQuit == true)
    #expect(AppConfig.parse("").confirmQuit == true)   // default on
    // Reserved: must not leak into the ghostty passthrough.
    #expect(AppConfig.parse("confirm-quit = false").ghostty.isEmpty)
    // Round-trips through rendered().
    let config = AppConfig(confirmQuit: false)
    #expect(AppConfig.parse(config.rendered()) == config)
}

@Test func configParsesNotificationKeys() {
    #expect(AppConfig.parse("notify-sound = false").notifySound == false)
    #expect(AppConfig.parse("notify-badge = false").notifyBadge == false)
    #expect(AppConfig.parse("notify-system = false").notifySystem == false)
    #expect(AppConfig.parse("").notifySound == true)    // defaults on
    #expect(AppConfig.parse("").notifyBadge == true)
    #expect(AppConfig.parse("").notifySystem == true)
    // Reserved: must not leak into the ghostty passthrough.
    #expect(AppConfig.parse("notify-sound = false\nnotify-badge = false\nnotify-system = false").ghostty.isEmpty)
    // Round-trips through rendered().
    let config = AppConfig(notifySound: false, notifyBadge: false, notifySystem: false)
    #expect(AppConfig.parse(config.rendered()) == config)
}

@Test func configParsesPreserveSessions() {
    #expect(AppConfig.parse("preserve-sessions = true").preserveSessions == true)
    #expect(AppConfig.parse("preserve-sessions = false").preserveSessions == false)
    #expect(AppConfig.parse("").preserveSessions == false)   // default off
    // Reserved: must not leak into the ghostty passthrough.
    #expect(AppConfig.parse("preserve-sessions = true").ghostty.isEmpty)
    // Round-trips through rendered().
    let config = AppConfig(preserveSessions: true)
    #expect(AppConfig.parse(config.rendered()) == config)
}

@Test func configParsesRestoreScrollback() {
    #expect(AppConfig.parse("restore-scrollback = false").restoreScrollback == false)
    #expect(AppConfig.parse("restore-scrollback = true").restoreScrollback == true)
    #expect(AppConfig.parse("").restoreScrollback == true)   // default on
    // Reserved: must not leak into the ghostty passthrough.
    #expect(AppConfig.parse("restore-scrollback = false").ghostty.isEmpty)
    // Round-trips through rendered().
    let config = AppConfig(restoreScrollback: false)
    #expect(AppConfig.parse(config.rendered()) == config)
}
