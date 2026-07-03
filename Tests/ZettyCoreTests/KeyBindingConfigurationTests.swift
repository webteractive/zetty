import Foundation
import Testing
@testable import ZettyCore

private func chord(_ text: String) -> KeyChord { KeyChord.parse(text)!.normalized }

// MARK: - Defaults

@Test func keybindingsDefaultsWhenNoConfigLines() {
    let bindings = AppConfig.parse("").keybindings
    #expect(bindings.prefix == chord("ctrl+b"))
    #expect(bindings.prefixTable == BindingCommand.defaultPrefixTable)
    #expect(bindings.copyTable == BindingCommand.defaultCopyTable)
    #expect(bindings.issues.isEmpty)
}

// MARK: - prefix =

@Test func keybindingsCustomPrefixHonored() {
    let config = AppConfig.parse("prefix = ctrl+space")
    #expect(config.keybindings.prefix == chord("ctrl+space"))
}

@Test func keybindingsInvalidPrefixKeepsDefaultAndReportsIssue() {
    let config = AppConfig.parse("prefix = ctrl+")
    #expect(config.keybindings.prefix == chord("ctrl+b"))
    #expect(config.keybindings.issues.count == 1)
}

// MARK: - bind =

@Test func keybindingsBindOverridesSingleChord() {
    let bindings = AppConfig.parse("bind = s split-vertical").keybindings
    #expect(bindings.prefixTable[chord("s")] == .splitVertical)
    // The rest of the defaults are untouched.
    #expect(bindings.prefixTable[chord("%")] == .splitVertical)
    #expect(bindings.prefixTable[chord("c")] == .newTab)
}

@Test func keybindingsRepeatedBindsAccumulateAndLastWinsPerChord() {
    let bindings = AppConfig.parse("""
    bind = s split-vertical
    bind = S split-horizontal
    bind = s close-pane
    """).keybindings
    #expect(bindings.prefixTable[chord("s")] == .closePane)
    #expect(bindings.prefixTable[chord("S")] == .splitHorizontal)
}

@Test func keybindingsBindSelectTab() {
    let config = AppConfig.parse("bind = t select-tab-4")
    #expect(config.keybindings.prefixTable[chord("t")] == .selectTab(4))
}

// MARK: - copy-bind =

@Test func keybindingsCopyBindTargetsCopyTable() {
    let bindings = AppConfig.parse("copy-bind = n copy-cursor-down").keybindings
    #expect(bindings.copyTable[chord("n")] == .copyCursorDown)
    // Prefix table untouched by copy-bind.
    #expect(bindings.prefixTable[chord("n")] == .nextTab)
    // Copy defaults otherwise intact.
    #expect(bindings.copyTable[chord("j")] == .copyCursorDown)
}

// MARK: - Bad lines

@Test func keybindingsBadChordAndUnknownCommandAreSkippedWithIssues() {
    let bindings = AppConfig.parse("""
    bind = ctrl+ split-vertical
    bind = s explode-pane
    bind = s
    copy-bind = q copy-exit
    """).keybindings
    #expect(bindings.issues.count == 3)
    #expect(bindings.prefixTable[chord("s")] == nil)
    #expect(bindings.copyTable[chord("q")] == .copyExit)
}

// MARK: - Persist round-trip

@Test func keybindingsRenderedPreservesCustomBindingLines() {
    let config = AppConfig.parse("""
    prefix = ctrl+a
    bind = s split-vertical
    copy-bind = n copy-cursor-down
    """)
    let reparsed = AppConfig.parse(config.rendered())
    #expect(reparsed.keybindings.prefix == chord("ctrl+a"))
    #expect(reparsed.keybindings.prefixTable[chord("s")] == .splitVertical)
    #expect(reparsed.keybindings.copyTable[chord("n")] == .copyCursorDown)
}

@Test func keybindingsDefaultFileParsesCleanly() {
    let config = AppConfig.parse(AppConfig.defaultFileContents)
    #expect(config.keybindings.issues.isEmpty)
    #expect(config.keybindings.prefix == chord("ctrl+b"))
}

// MARK: - Coexistence with ghostty directives

@Test func keybindingsGhosttyKeybindStillForwards() {
    let config = AppConfig.parse("""
    prefix = ctrl+a
    keybind = ctrl+d=new_split:right
    bind = s split-vertical
    """)
    #expect(config.keybindings.prefix == chord("ctrl+a"))
    #expect(config.ghostty == [GhosttyDirective(key: "keybind", value: "ctrl+d=new_split:right")])
}
