import Foundation
import Testing
@testable import ZettyCore

@Test func sessionsViewDefaultsToTheDrawer() {
    #expect(AppConfig.parse("").sessionsView == .drawer)
}

@Test func sessionsViewParsesBothForms() {
    #expect(AppConfig.parse("zetty-sessions-view = window").sessionsView == .window)
    #expect(AppConfig.parse("zetty-sessions-view = drawer").sessionsView == .drawer)
    #expect(AppConfig.parse("zetty-sessions-view = WINDOW").sessionsView == .window)
}

@Test func anUnknownValueKeepsTheDefaultRatherThanBreakingTheConfig() {
    // ghostty validates all-or-nothing, so a typo here must not cost the whole
    // file — that is how preserve-sessions once got silently disabled.
    #expect(AppConfig.parse("zetty-sessions-view = sideways").sessionsView == .drawer)
}

@Test func theSettingRoundTripsThroughRendered() {
    // The detach and dock buttons persist by rewriting the file, so a value
    // that does not survive rendering would revert on the next launch.
    var config = AppConfig.parse("")
    config.sessionsView = .window
    #expect(AppConfig.parse(config.rendered()).sessionsView == .window)

    config.sessionsView = .drawer
    #expect(AppConfig.parse(config.rendered()).sessionsView == .drawer)
}

@Test func theKeyNeverReachesGhostty() {
    // A `zetty-` key forwarded to libghostty fails its all-or-nothing
    // validation and drops the whole config, including per-surface commands.
    #expect(AppConfig.parse("zetty-sessions-view = window").rendered()
        .contains("zetty-sessions-view"))
    #expect(AppConfig.parse("zetty-sessions-view = window")
        .ghostty.contains { $0.key == "zetty-sessions-view" } == false)
}

// MARK: - zetty-tile-manager-view

@Test func tileManagerViewIsItsOwnSettingDefaultingToTheDrawer() {
    #expect(AppConfig.parse("").tileManagerView == .drawer)
    // Independent of Sessions: detaching one must not move the other.
    let config = AppConfig.parse("zetty-sessions-view = window")
    #expect(config.tileManagerView == .drawer)
    #expect(AppConfig.parse("zetty-tile-manager-view = Window").tileManagerView == .window)
    #expect(AppConfig.parse("zetty-tile-manager-view = sideways").tileManagerView == .drawer)
}

@Test func tileManagerViewRoundTripsAndNeverReachesGhostty() {
    var config = AppConfig.parse("")
    config.tileManagerView = .window
    let rendered = config.rendered()
    #expect(AppConfig.parse(rendered).tileManagerView == .window)
    #expect(AppConfig.parse(rendered).ghostty.contains { $0.key == "zetty-tile-manager-view" } == false)
}
