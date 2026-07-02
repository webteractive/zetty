import Testing
import Foundation
@testable import QuerttyCore

private let idA = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
private let idB = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

@Test func sessionNameIsStableShortHexOfUUID() {
    #expect(SessionPersistence.sessionName(for: idA) == "quertty-abcdef01")
    // Deterministic: same UUID → same name (relaunch reattaches).
    #expect(SessionPersistence.sessionName(for: idA) == SessionPersistence.sessionName(for: idA))
}

@Test func attachCommandUsesZmxPathAndName() {
    let cmd = SessionPersistence.attachCommand(zmxPath: "/opt/homebrew/bin/zmx", surfaceID: idA)
    // ZMX_SESSION must be stripped: if quertty was launched from inside a
    // zmx-backed terminal (e.g. Supacode), an inherited ZMX_SESSION makes
    // `zmx attach` kill that session instead of attaching ours.
    #expect(cmd == "/usr/bin/env -u ZMX_SESSION /opt/homebrew/bin/zmx attach quertty-abcdef01")
}

@Test func listParsingKeepsOnlyQuerttySessions() {
    let output = """
    quertty-abcdef01
    someone-elses-session

    quertty-11111111
    """
    #expect(SessionPersistence.querttySessions(fromList: output) == ["quertty-abcdef01", "quertty-11111111"])
}

@Test func orphanDiffingExcludesLiveSurfaces() {
    let existing = ["quertty-abcdef01", "quertty-11111111", "quertty-deadbeef"]
    let orphans = SessionPersistence.orphans(existing: existing, liveSurfaceIDs: [idA, idB])
    #expect(orphans == ["quertty-deadbeef"])
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
