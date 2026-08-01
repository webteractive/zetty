import Foundation
import Testing
@testable import ZettyCore

@Test func freeBackgroundPanesAfterParsesDurations() {
    #expect(AppConfig.parse("free-background-panes-after = 90").freeBackgroundPanesAfter == 90)
    #expect(AppConfig.parse("free-background-panes-after = 5m").freeBackgroundPanesAfter == 300)
    #expect(AppConfig.parse("free-background-panes-after = 2h").freeBackgroundPanesAfter == 7200)
}

@Test func freeBackgroundPanesAfterDefaultsToOff() {
    #expect(AppConfig().freeBackgroundPanesAfter == 0)
    #expect(AppConfig.parse("free-background-panes-after = off").freeBackgroundPanesAfter == 0)
    #expect(AppConfig.parse("free-background-panes-after = garbage").freeBackgroundPanesAfter == 0)
}

/// Same trap as the viewer keys: one key ghostty rejects discards the ENTIRE
/// config, including the per-surface `command` behind session preservation, so
/// panes would launch plain shells and strand their preserved sessions.
@Test func freeBackgroundPanesKeyNeverReachesGhostty() {
    let config = AppConfig.parse("free-background-panes-after = 5m")
    #expect(config.ghostty.isEmpty)
    #expect(config.unsupportedKeys.isEmpty)
}

@Test func freeBackgroundPanesSurvivesARenderReparseRoundTrip() {
    var config = AppConfig()
    config.freeBackgroundPanesAfter = 600
    let reparsed = AppConfig.parse(config.rendered())
    #expect(reparsed.freeBackgroundPanesAfter == 600)
    #expect(reparsed.ghostty.isEmpty)
}

@Test func offSurvivesARenderReparseRoundTrip() {
    let reparsed = AppConfig.parse(AppConfig().rendered())
    #expect(reparsed.freeBackgroundPanesAfter == 0)
    #expect(reparsed.ghostty.isEmpty)
}

// MARK: - Orphan cwd files

@Test func orphanCwdFilesFindsOnlyUnownedPaneFiles() {
    let owned = UUID()
    let gone = UUID()
    let names = ["\(owned.uuidString).cwd", "\(gone.uuidString).cwd"]
    let orphans = SessionPersistence.orphanCwdFiles(existing: names, liveSurfaceIDs: [owned])
    #expect(orphans == ["\(gone.uuidString).cwd"])
}

@Test func orphanCwdFilesIgnoresAnythingItCannotParse() {
    // This drives deletion, so an unrecognized name must never be an orphan.
    let names = ["notes.txt", "README", ".DS_Store", "not-a-uuid.cwd", "abc.cwd"]
    #expect(SessionPersistence.orphanCwdFiles(existing: names, liveSurfaceIDs: []).isEmpty)
}

@Test func orphanCwdFilesMatchesCaseInsensitively() {
    let owned = UUID()
    let lower = ["\(owned.uuidString.lowercased()).cwd"]
    #expect(SessionPersistence.orphanCwdFiles(existing: lower, liveSurfaceIDs: [owned]).isEmpty)
}
