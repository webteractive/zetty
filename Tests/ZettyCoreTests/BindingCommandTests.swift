import Foundation
import Testing
@testable import ZettyCore

private func prefixDefault(_ chordText: String) -> BindingCommand? {
    BindingCommand.defaultPrefixTable[KeyChord.parse(chordText)!.normalized]
}

private func copyDefault(_ chordText: String) -> BindingCommand? {
    BindingCommand.defaultCopyTable[KeyChord.parse(chordText)!.normalized]
}

// MARK: - Config-name round-trip

@Test func commandConfigNameRoundTripsForEveryPrefixCommand() {
    let commands: [BindingCommand] = [
        .splitVertical, .splitHorizontal,
        .focusLeft, .focusRight, .focusUp, .focusDown, .cyclePanes,
        .closePane, .zoomPane, .breakPane,
        .newTab, .nextTab, .previousTab, .renameTab,
        .enterCopyMode, .paste, .sendPrefixLiteral, .cancelPrefix,
    ]
    for command in commands {
        #expect(BindingCommand(configName: command.configName) == command,
                "round-trip failed for \(command.configName)")
    }
}

@Test func commandConfigNameRoundTripsForBroadcast() {
    #expect(BindingCommand.broadcastToggle.configName == "broadcast-toggle")
    #expect(BindingCommand.broadcastAgentsToggle.configName == "broadcast-agents-toggle")
    #expect(BindingCommand(configName: "broadcast-toggle") == .broadcastToggle)
    #expect(BindingCommand(configName: "broadcast-agents-toggle") == .broadcastAgentsToggle)
}

@Test func commandConfigNameRoundTripsForSelectTab() {
    for n in 1...9 {
        let command = BindingCommand.selectTab(n)
        #expect(command.configName == "select-tab-\(n)")
        #expect(BindingCommand(configName: "select-tab-\(n)") == command)
    }
}

@Test func commandConfigNameRoundTripsForEveryCopyCommand() {
    let commands: [BindingCommand] = [
        .copyCursorLeft, .copyCursorRight, .copyCursorUp, .copyCursorDown,
        .copyWordForward, .copyWordBackward, .copyWordEnd,
        .copyLineStart, .copyLineEnd,
        .copyScrollTop, .copyScrollBottom,
        .copyHalfPageUp, .copyHalfPageDown, .copyPageUp, .copyPageDown,
        .copyBeginSelection, .copyBeginLineSelection,
        .copyYank, .copyExit,
    ]
    for command in commands {
        #expect(BindingCommand(configName: command.configName) == command,
                "round-trip failed for \(command.configName)")
    }
}

@Test func commandUnknownConfigNamesRejected() {
    #expect(BindingCommand(configName: "explode") == nil)
    #expect(BindingCommand(configName: "") == nil)
    #expect(BindingCommand(configName: "select-tab-0") == nil)
    #expect(BindingCommand(configName: "select-tab-10") == nil)
    #expect(BindingCommand(configName: "select-tab-x") == nil)
}

@Test func breakPaneBoundToBangByDefault() {
    #expect(prefixDefault("!") == .breakPane)
    #expect(BindingCommand(configName: "break-pane") == .breakPane)
}

// MARK: - Default prefix table (tmux canon)

@Test func defaultPrefixTableMatchesDesignDoc() {
    #expect(prefixDefault("%") == .splitVertical)
    #expect(prefixDefault("\"") == .splitHorizontal)
    #expect(prefixDefault("h") == .focusLeft)
    #expect(prefixDefault("j") == .focusDown)
    #expect(prefixDefault("k") == .focusUp)
    #expect(prefixDefault("l") == .focusRight)
    #expect(prefixDefault("left") == .focusLeft)
    #expect(prefixDefault("down") == .focusDown)
    #expect(prefixDefault("up") == .focusUp)
    #expect(prefixDefault("right") == .focusRight)
    #expect(prefixDefault("o") == .cyclePanes)
    #expect(prefixDefault("x") == .closePane)
    #expect(prefixDefault("z") == .zoomPane)
    #expect(prefixDefault("!") == .breakPane)
    #expect(prefixDefault("c") == .newTab)
    #expect(prefixDefault("n") == .nextTab)
    #expect(prefixDefault("p") == .previousTab)
    #expect(prefixDefault(",") == .renameTab)
    #expect(prefixDefault("[") == .enterCopyMode)
    #expect(prefixDefault("]") == .paste)
    for n in 1...9 {
        #expect(prefixDefault("\(n)") == .selectTab(n))
    }
}

// MARK: - Default copy table (vi keys)

@Test func defaultCopyTableMatchesDesignDoc() {
    #expect(copyDefault("h") == .copyCursorLeft)
    #expect(copyDefault("j") == .copyCursorDown)
    #expect(copyDefault("k") == .copyCursorUp)
    #expect(copyDefault("l") == .copyCursorRight)
    #expect(copyDefault("left") == .copyCursorLeft)
    #expect(copyDefault("down") == .copyCursorDown)
    #expect(copyDefault("up") == .copyCursorUp)
    #expect(copyDefault("right") == .copyCursorRight)
    #expect(copyDefault("w") == .copyWordForward)
    #expect(copyDefault("b") == .copyWordBackward)
    #expect(copyDefault("e") == .copyWordEnd)
    #expect(copyDefault("0") == .copyLineStart)
    #expect(copyDefault("$") == .copyLineEnd)
    #expect(copyDefault("g") == .copyScrollTop)
    #expect(copyDefault("G") == .copyScrollBottom)
    #expect(copyDefault("ctrl+u") == .copyHalfPageUp)
    #expect(copyDefault("ctrl+d") == .copyHalfPageDown)
    #expect(copyDefault("ctrl+b") == .copyPageUp)
    #expect(copyDefault("ctrl+f") == .copyPageDown)
    #expect(copyDefault("v") == .copyBeginSelection)
    #expect(copyDefault("V") == .copyBeginLineSelection)
    #expect(copyDefault("y") == .copyYank)
    #expect(copyDefault("enter") == .copyYank)
    #expect(copyDefault("escape") == .copyExit)
    #expect(copyDefault("q") == .copyExit)
}
