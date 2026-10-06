import Foundation
import Testing
@testable import ZettyCore

private let mod = "/Users/me/.zetty/mods/zetty-bridge"
private let key = ModInstall.pluginDirsVariable

private func dirs(_ settings: [String: Any]) -> String? {
    (settings["env"] as? [String: Any])?[key] as? String
}

@Test func settingsWithoutThePluginListAreLeftAlone() {
    // The process environment already carries the mod there.
    let settings: [String: Any] = ["env": ["OTHER": "1"], "theme": "dark"]
    let merged = ModInstall.settingsLoadingMod(settings, modPath: mod, enabled: true)
    #expect(NSDictionary(dictionary: merged).isEqual(to: settings))
    #expect(NSDictionary(dictionary: ModInstall.settingsLoadingMod([:], modPath: mod, enabled: true)).isEqual(to: [:]))
}

@Test func aSettingsPluginListGainsTheModOnceAndKeepsItsOrder() {
    let settings: [String: Any] = ["env": [key: "/a/warden:/b/hydra", "OTHER": "1"]]
    let merged = ModInstall.settingsLoadingMod(settings, modPath: mod, enabled: true)
    #expect(dirs(merged) == "/a/warden:/b/hydra:\(mod)")
    #expect((merged["env"] as? [String: Any])?["OTHER"] as? String == "1")
    let again = ModInstall.settingsLoadingMod(merged, modPath: mod, enabled: true)
    #expect(dirs(again) == "/a/warden:/b/hydra:\(mod)")
}

@Test func disablingRemovesOnlyTheModFromTheSettingsList() {
    let settings: [String: Any] = ["env": [key: "/a/warden:\(mod):/b/hydra"]]
    #expect(dirs(ModInstall.settingsLoadingMod(settings, modPath: mod, enabled: false)) == "/a/warden:/b/hydra")
}

@Test func disablingALoneModRemovesTheKeyButKeepsTheEnvBlock() {
    let settings: [String: Any] = ["env": [key: mod, "OTHER": "1"]]
    let merged = ModInstall.settingsLoadingMod(settings, modPath: mod, enabled: false)
    #expect(dirs(merged) == nil)
    #expect((merged["env"] as? [String: Any])?["OTHER"] as? String == "1")
}
