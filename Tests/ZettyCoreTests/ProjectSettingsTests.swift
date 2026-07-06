import Testing
import Foundation
@testable import ZettyCore

@Test func projectSettingsRoundTripsThroughJSON() throws {
    let settings = ProjectSettings(
        name: "API", color: "teal", icon: "server.rack",
        preserveSessionsOverride: true, notificationsOverride: false)
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(ProjectSettings.self, from: data)
    #expect(decoded == settings)
}

@Test func projectSettingsDecodesForwardCompatibly() throws {
    // Fields added later (or written by a newer version) must not break decode.
    let json = #"{"name":"API","futureField":42}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ProjectSettings.self, from: json)
    #expect(decoded.name == "API")
    #expect(decoded.preserveSessionsOverride == nil)
}

@Test func projectSettingsIsEmptyWhenAllNil() {
    #expect(ProjectSettings().isEmpty)
    #expect(!ProjectSettings(name: "x").isEmpty)
    #expect(!ProjectSettings(notificationsOverride: false).isEmpty)
}

@Test func canonicalKeyNormalizesPaths() {
    let home = NSHomeDirectory()
    #expect(ProjectSettingsStore.canonicalKey("~/AI/zetty") == "\(home)/AI/zetty")
    // Trailing slash and dot-segments normalize; note Foundation does NOT
    // unify /tmp with /private/tmp here — acceptable, since rootPaths come
    // from consistent sources (panel/CLI absolute paths), never mixed aliases.
    #expect(ProjectSettingsStore.canonicalKey("/tmp/x/") == "/tmp/x")
    #expect(ProjectSettingsStore.canonicalKey("/a/b/../c") == "/a/c")
}

@Test func settingsFileLookupUsesCanonicalKeys() {
    var file = ProjectSettingsFile()
    file.set(ProjectSettings(name: "Zetty"), for: "\(NSHomeDirectory())/AI/zetty/")
    #expect(file.settings(for: "~/AI/zetty")?.name == "Zetty")
}

@Test func settingsFileDropsEmptyEntries() {
    var file = ProjectSettingsFile()
    file.set(ProjectSettings(name: "X"), for: "/a")
    file.set(ProjectSettings(), for: "/a")   // cleared → entry removed
    #expect(file.settings(for: "/a") == nil)
    #expect(file.settings.isEmpty)
}

@Test func anyPreserveOverrideOnDetectsOnlyTrue() {
    var file = ProjectSettingsFile()
    #expect(!file.anyPreserveOverrideOn)
    file.set(ProjectSettings(preserveSessionsOverride: false), for: "/a")
    #expect(!file.anyPreserveOverrideOn)
    file.set(ProjectSettings(preserveSessionsOverride: true), for: "/b")
    #expect(file.anyPreserveOverrideOn)
}

@Test func storeRoundTripsAndToleratesMissingOrCorruptFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-ps-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProjectSettingsStore(directory: dir)

    #expect(store.load() == ProjectSettingsFile())          // missing → empty

    var file = ProjectSettingsFile()
    file.set(ProjectSettings(name: "API", color: "sky"), for: "/work/api")
    try store.save(file)
    #expect(store.load() == file)                           // round-trip

    try "not json".write(to: dir.appendingPathComponent("project-settings.json"),
                         atomically: true, encoding: .utf8)
    #expect(store.load() == ProjectSettingsFile())          // corrupt → empty, no throw
}

@Test func projectSettingsCarriesAppearanceAndThemeOverrides() throws {
    let settings = ProjectSettings(
        appearanceOverride: "dark", themeDarkOverride: "Ember", themeLightOverride: "Sakura")
    #expect(!settings.isEmpty)
    let decoded = try JSONDecoder().decode(
        ProjectSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.appearanceOverride == "dark")
    #expect(decoded.themeDarkOverride == "Ember")
    #expect(decoded.themeLightOverride == "Sakura")
    // The retired single-scheme key from the interim design is just an
    // unknown key now — tolerated, dropped.
    let legacy = #"{"themeOverride":"Ember"}"#.data(using: .utf8)!
    #expect(try JSONDecoder().decode(ProjectSettings.self, from: legacy).isEmpty)
}

@Test func projectSettingsCarriesEnv() throws {
    let settings = ProjectSettings(env: ["API_KEY": "abc 123", "DB_URL": "postgres://x"])
    #expect(!settings.isEmpty)
    let decoded = try JSONDecoder().decode(
        ProjectSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.env?["API_KEY"] == "abc 123")
}

@Test func projectSettingsRoundTripsAgents() throws {
    var s = ProjectSettings()
    s.agents = [ProjectAgent(id: "claude", command: "claude"),
                ProjectAgent(id: "cursor", command: "cursor-agent")]
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(ProjectSettings.self, from: data)
    #expect(decoded.agents == s.agents)
    #expect(!s.isEmpty)
}

@Test func projectSettingsAgentsNilStaysEmpty() {
    #expect(ProjectSettings().agents == nil)
    #expect(ProjectSettings().isEmpty)
}

@Test func projectSettingsTolerantDecodeWithoutAgents() throws {
    // A file written before this field existed decodes with agents == nil.
    let json = #"{"name":"X"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ProjectSettings.self, from: json)
    #expect(decoded.name == "X")
    #expect(decoded.agents == nil)
}
