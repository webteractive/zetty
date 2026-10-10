import Foundation
import Testing
@testable import ZettyCore

private func chord(_ text: String) -> KeyChord { KeyChord.parse(text)!.normalized }

// MARK: - Key bindings

@Test func bindingEditorSplitsPrefixFromBindLines() {
    let config = AppConfig.parse("""
    prefix = ctrl+a
    bind = s split-vertical
    copy-bind = n copy-cursor-down
    """)
    #expect(config.prefixSourceValue == "ctrl+a")
    #expect(config.bindingLinesText == "bind = s split-vertical\ncopy-bind = n copy-cursor-down")
}

@Test func bindingEditorReportsDefaultPrefixAsNil() {
    #expect(AppConfig.parse("bind = s split-vertical").prefixSourceValue == nil)
}

@Test func settingKeybindingsReplacesEveryLine() {
    let start = AppConfig.parse("prefix = ctrl+a\nbind = s split-vertical")
    let result = start.settingKeybindings(prefix: "", lines: "copy-bind = n copy-cursor-down")
    #expect(result.issues.isEmpty)
    #expect(result.config.keybindings.prefix == chord("ctrl+b"))
    #expect(result.config.keybindings.sourceLines == ["copy-bind = n copy-cursor-down"])
    #expect(result.config.keybindings.prefixTable == BindingCommand.defaultPrefixTable)
}

@Test func settingKeybindingsKeepsTmuxPassthrough() {
    let start = AppConfig.parse("zetty-tmux-passthrough = false")
    let result = start.settingKeybindings(prefix: "ctrl+a", lines: "")
    #expect(result.config.keybindings.passPrefixToMultiplexer == false)
    #expect(result.config.keybindings.prefix == chord("ctrl+a"))
}

@Test func settingKeybindingsReportsBadLinesAndSkipsComments() {
    let result = AppConfig().settingKeybindings(prefix: "ctrl+", lines: """
    # a comment

    bind = s not-a-command
    prefix = ctrl+a
    font-size = 14
    """)
    #expect(result.issues.count == 4)
    #expect(result.config.keybindings.sourceLines.isEmpty)
}

@Test func settingKeybindingsRoundTripsThroughTheFile() {
    let result = AppConfig().settingKeybindings(prefix: "ctrl+a", lines: "bind = s split-vertical")
    let reparsed = AppConfig.parse(result.config.rendered())
    #expect(reparsed.keybindings == result.config.keybindings)
}

// MARK: - Ghostty directives

@Test func ghosttyEditorListsDirectivesInOrder() {
    let config = AppConfig.parse("font-size = 14\nkeybind = a=b\nkeybind = c=d")
    #expect(config.ghosttyDirectivesText == "font-size = 14\nkeybind = a=b\nkeybind = c=d")
}

@Test func settingGhosttyDirectivesReplacesTheBlock() {
    let start = AppConfig.parse("font-size = 14")
    let result = start.settingGhosttyDirectives("cursor-style = bar\n\n# note\nkeybind = a=b")
    #expect(result.issues.isEmpty)
    #expect(result.config.ghostty == [
        GhosttyDirective(key: "cursor-style", value: "bar"),
        GhosttyDirective(key: "keybind", value: "a=b"),
    ])
}

@Test func settingGhosttyDirectivesRejectsZettyKeys() {
    let result = AppConfig().settingGhosttyDirectives("""
    appearance = dark
    zetty-file-tree-width = 300
    bind = s split-vertical
    cursor-style = bar
    """)
    #expect(result.issues.count == 3)
    #expect(result.config.ghostty == [GhosttyDirective(key: "cursor-style", value: "bar")])
    #expect(result.config.appearance == .system)
}

@Test func settingGhosttyDirectivesRejectsMalformedLines() {
    let result = AppConfig().settingGhosttyDirectives("cursor-style\n= bar\nfont-size =")
    #expect(result.issues.count == 3)
    #expect(result.config.ghostty.isEmpty)
}

@Test func settingGhosttyDirectivesKeepsColorValues() {
    let result = AppConfig().settingGhosttyDirectives("background = #101010")
    #expect(result.config.ghostty == [GhosttyDirective(key: "background", value: "#101010")])
}
