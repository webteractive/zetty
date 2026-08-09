import Foundation
import Testing
@testable import ZettyCore

@Test func toggleFileTreeHasAConfigName() {
    #expect(BindingCommand.toggleFileTree.configName == "toggle-file-tree")
}

@Test func toggleFileTreeParsesFromItsConfigName() {
    #expect(BindingCommand(configName: "toggle-file-tree") == .toggleFileTree)
}

@Test func prefixEIsBoundToToggleFileTreeByDefault() {
    let chord = KeyChord.parse("e")!.normalized
    #expect(BindingCommand.defaultPrefixTable[chord] == .toggleFileTree)
}

@Test func toggleFileTreeCanBeRebound() {
    var configuration = KeyBindingConfiguration()
    configuration.applyBind("f toggle-file-tree", toCopyTable: false)
    let chord = KeyChord.parse("f")!.normalized
    #expect(configuration.prefixTable[chord] == .toggleFileTree)
    #expect(configuration.issues.isEmpty)
}

/// An accepted `bind` line must survive a config persist.
@Test func reboundToggleSurvivesARenderRoundTrip() {
    let original = AppConfig.parse("bind = f toggle-file-tree")
    let reparsed = AppConfig.parse(original.rendered())
    let chord = KeyChord.parse("f")!.normalized
    #expect(reparsed.keybindings.prefixTable[chord] == .toggleFileTree)
}
