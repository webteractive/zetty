import Testing
@testable import ZettyCore

@Test func viewerKeysHaveDefaults() {
    let config = AppConfig()
    #expect(config.viewerHighlightCommand == "bat --style=plain --color=always --paging=never")
    #expect(config.viewerMaxBytes == 2_097_152)
}

@Test func viewerKeysParse() {
    let config = AppConfig.parse("""
    viewer-highlight-command = highlight -O ansi
    viewer-max-bytes = 4096
    """)
    #expect(config.viewerHighlightCommand == "highlight -O ansi")
    #expect(config.viewerMaxBytes == 4096)
}

@Test func viewerHighlightCanBeDisabled() {
    for value in ["off", "none", "false"] {
        let config = AppConfig.parse("viewer-highlight-command = \(value)")
        #expect(config.viewerHighlightCommand.isEmpty)
    }
}

@Test func viewerMaxBytesIgnoresNonsense() {
    let config = AppConfig.parse("viewer-max-bytes = banana")
    #expect(config.viewerMaxBytes == 2_097_152)
    let negative = AppConfig.parse("viewer-max-bytes = -5")
    #expect(negative.viewerMaxBytes == 2_097_152)
}

/// The whole point: a Zetty key must NEVER be forwarded to ghostty. One key
/// ghostty rejects discards the entire config — including the per-surface
/// `command` — which strands preserved zmx sessions behind plain shells.
@Test func viewerKeysNeverReachGhostty() {
    let config = AppConfig.parse("""
    viewer-highlight-command = bat --color=always
    viewer-max-bytes = 4096
    """)
    #expect(config.ghostty.isEmpty)
    #expect(config.unsupportedKeys.isEmpty)
}

@Test func viewerKeysSurviveARenderReparseRoundTrip() {
    var config = AppConfig()
    config.viewerHighlightCommand = "highlight -O ansi"
    config.viewerMaxBytes = 4096
    let reparsed = AppConfig.parse(config.rendered())
    #expect(reparsed.viewerHighlightCommand == "highlight -O ansi")
    #expect(reparsed.viewerMaxBytes == 4096)
    #expect(reparsed.ghostty.isEmpty)
}

@Test func disabledHighlightSurvivesARoundTrip() {
    var config = AppConfig()
    config.viewerHighlightCommand = ""
    let reparsed = AppConfig.parse(config.rendered())
    #expect(reparsed.viewerHighlightCommand.isEmpty)
    #expect(reparsed.ghostty.isEmpty)
}
