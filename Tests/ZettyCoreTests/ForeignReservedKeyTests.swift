import Testing
import Foundation
@testable import ZettyCore

/// Regression: a Zetty key this build doesn't implement must NOT be forwarded
/// to ghostty.
///
/// libghostty rejects its ENTIRE config when any key produces a diagnostic
/// (`TerminalController+Config.prepareConfig` frees the config and fails), so
/// one unrecognized directive silently drops every custom setting — including
/// the per-surface `command` that implements session preservation. Panes then
/// launch a plain shell instead of `zmx attach`, and every preserved session is
/// stranded on relaunch.
///
/// This happened for real with `notify-poke`, written into the config by a
/// feature-branch build and then unknown to main.
@Test func unknownNotifyKeyIsNotForwardedToGhostty() {
    let config = AppConfig.parse("notify-poke   = false")
    #expect(config.ghostty.isEmpty)
    #expect(config.unsupportedKeys == ["notify-poke"])
}

/// The `notify-` namespace is Zetty's alone — ghostty defines no such key — so
/// any future `notify-*` is swallowed rather than poisoning the passthrough.
@Test func unknownNotifyKeysAreSwallowedButRealOnesStillParse() {
    let config = AppConfig.parse("""
    notify-sound = false
    notify-future-thing = true
    """)
    #expect(config.notifySound == false)      // known key still parses
    #expect(config.ghostty.isEmpty)           // unknown notify-* not forwarded
    #expect(config.unsupportedKeys == ["notify-future-thing"])
}

/// Retired non-`notify-` Zetty keys are reserved too.
@Test func retiredZettyKeysAreReserved() {
    for key in AppConfig.retiredReservedKeys {
        let config = AppConfig.parse("\(key) = whatever")
        #expect(config.ghostty.isEmpty, "\(key) leaked into the ghostty passthrough")
    }
}

@Test func confirmQuitIsRetiredAndDroppedOnRender() {
    let config = AppConfig.parse("confirm-quit = false\nfont-size = 14")
    #expect(config.ghostty.count == 1)
    #expect(config.unsupportedKeys == ["confirm-quit"])
    #expect(!config.rendered().contains("confirm-quit"))
}

/// Genuine ghostty directives must still pass through untouched — the whole
/// point of the passthrough is pasting an existing ghostty config.
@Test func realGhosttyDirectivesStillPassThrough() {
    let config = AppConfig.parse("""
    font-family = Andale Mono
    font-size = 14
    cursor-style = bar
    """)
    #expect(config.ghostty.count == 3)
    #expect(config.unsupportedKeys.isEmpty)
    #expect(config.ghosttyValue("font-family") == "Andale Mono")
}

/// Unsupported keys must not be re-emitted by `rendered()` — otherwise the key
/// survives every runtime persist and keeps breaking future launches.
@Test func unsupportedKeysAreDroppedOnRender() {
    let config = AppConfig.parse("notify-poke = false\nfont-size = 14")
    let rendered = config.rendered()
    #expect(!rendered.contains("notify-poke"))
    #expect(AppConfig.parse(rendered).ghosttyValue("font-size") == "14")
}
