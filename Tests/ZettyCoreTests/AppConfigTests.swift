import Foundation
import Testing
@testable import ZettyCore

@Test func configDefaultsWhenEmpty() {
    let c = AppConfig.parse("")
    #expect(c.appearance == .system)
    #expect(c.themeDark == "Twilight")
    #expect(c.themeLight == "Daylight")
}

@Test func configParsesAllKeys() {
    let text = """
    appearance = dark
    theme-dark = Twilight
    theme-light = Frost
    """
    let c = AppConfig.parse(text)
    #expect(c.appearance == .dark)
    #expect(c.themeDark == "Twilight")
    #expect(c.themeLight == "Frost")
}

@Test func configIgnoresCommentsAndBlankLines() {
    let text = """
    # a comment

      theme-dark = Ember
    appearance = light

    # trailing comment
    """
    let c = AppConfig.parse(text)
    #expect(c.appearance == .light)
    #expect(c.themeDark == "Ember")
    #expect(c.themeLight == "Daylight") // untouched → default
}

@Test func configForwardsPastedGhosttyLines() {
    // Reserved keys stay Zetty's; everything else is forwarded verbatim.
    let text = """
    appearance = dark
    theme-dark = Frost
    font-family = JetBrains Mono
    cursor-style = bar
    background = #1e1e2e
    keybind = ctrl+a=new_tab
    """
    let c = AppConfig.parse(text)
    #expect(c.appearance == .dark)
    #expect(c.themeDark == "Frost")
    #expect(c.ghostty == [
        GhosttyDirective(key: "font-family", value: "JetBrains Mono"),
        GhosttyDirective(key: "cursor-style", value: "bar"),
        GhosttyDirective(key: "background", value: "#1e1e2e"),   // inline # preserved
        GhosttyDirective(key: "keybind", value: "ctrl+a=new_tab"),
    ])
}

@Test func configGhosttyPassthroughRoundTrips() {
    let config = AppConfig(appearance: .dark, ghostty: [
        GhosttyDirective(key: "font-size", value: "14"),
        GhosttyDirective(key: "window-padding-x", value: "8"),
    ])
    #expect(AppConfig.parse(config.rendered()) == config)
}

@Test func configKeysAreCaseInsensitiveAndTrimmed() {
    let text = "  APPEARANCE  =  Dark  \n THEME-DARK = Nocturne "
    let c = AppConfig.parse(text)
    #expect(c.appearance == .dark)
    #expect(c.themeDark == "Nocturne")
}

@Test func configEditorIsReservedNotPassthrough() {
    let c = AppConfig.parse("editor = Zed\nfont-size = 14")
    #expect(c.editor == "Zed")
    // `editor` must not leak into the ghostty passthrough.
    #expect(c.ghostty == [GhosttyDirective(key: "font-size", value: "14")])
    // Defaults to nil, and round-trips through rendered().
    #expect(AppConfig.parse("").editor == nil)
    #expect(AppConfig.parse(c.rendered()) == c)
}

@Test func configBadAppearanceValueDefaults() {
    let c = AppConfig.parse("appearance = neon\ntheme-dark = Frost")
    #expect(c.appearance == .system)   // "neon" invalid → default
    #expect(c.themeDark == "Frost")    // valid reserved key still applied
    #expect(c.ghostty.isEmpty)
}

@Test func configStoreSeedsAndReloadsFromDisk() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-config-test-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("config")
    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

    let store = ConfigStore(fileURL: tmp)
    // First load: file missing → defaults returned and default file seeded.
    let first = store.load()
    #expect(first == AppConfig())
    #expect(FileManager.default.fileExists(atPath: tmp.path))

    // The seeded file must itself parse back to the defaults.
    let seeded = AppConfig.parse(try String(contentsOf: tmp, encoding: .utf8))
    #expect(seeded == AppConfig())

    // A user edit is read back on the next load.
    try "appearance = light\ntheme-light = Paper".write(to: tmp, atomically: true, encoding: .utf8)
    #expect(store.load().appearance == .light)
}

@Test func configStoreSavesAndReloadsRoundTrip() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-config-save-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("config")
    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

    let store = ConfigStore(fileURL: tmp)
    let config = AppConfig(appearance: .dark, themeDark: "Frost", themeLight: "Paper")
    store.save(config)
    #expect(store.load() == config)
}

@Test func configParsesSidebarPosition() {
    #expect(AppConfig.parse("sidebar-position = right").sidebarPosition == .right)
    #expect(AppConfig.parse("sidebar-position = LEFT").sidebarPosition == .left)
    // Missing or invalid values fall back to the default (left).
    #expect(AppConfig.parse("").sidebarPosition == .left)
    #expect(AppConfig.parse("sidebar-position = middle").sidebarPosition == .left)
}

@Test func configRendersSidebarPositionRoundTrip() {
    var config = AppConfig()
    config.sidebarPosition = .right
    #expect(AppConfig.parse(config.rendered()) == config)
}

// MARK: - Ghostty directive helpers (Settings-driven font controls)

@Test func ghosttyValueReadsLastWins() {
    let c = AppConfig(ghostty: [
        GhosttyDirective(key: "font-size", value: "12"),
        GhosttyDirective(key: "cursor-style", value: "bar"),
        GhosttyDirective(key: "font-size", value: "16"),
    ])
    #expect(c.ghosttyValue("font-size") == "16")
    #expect(c.ghosttyValue("cursor-style") == "bar")
    #expect(c.ghosttyValue("font-family") == nil)
}

@Test func ghosttyValueMatchesKeysCaseInsensitively() {
    let c = AppConfig(ghostty: [GhosttyDirective(key: "Font-Family", value: "Fira Code")])
    #expect(c.ghosttyValue("font-family") == "Fira Code")
    #expect(c.ghosttyValue("FONT-FAMILY") == "Fira Code")
}

@Test func settingGhosttyAppendsWhenAbsent() {
    let c = AppConfig(ghostty: [GhosttyDirective(key: "cursor-style", value: "bar")])
        .settingGhostty(key: "font-size", value: "15")
    #expect(c.ghostty == [
        GhosttyDirective(key: "cursor-style", value: "bar"),
        GhosttyDirective(key: "font-size", value: "15"),
    ])
}

@Test func settingGhosttyReplacesLastInPlaceAndCollapsesDuplicates() {
    let c = AppConfig(ghostty: [
        GhosttyDirective(key: "font-size", value: "12"),
        GhosttyDirective(key: "cursor-style", value: "bar"),
        GhosttyDirective(key: "font-size", value: "16"),
    ]).settingGhostty(key: "font-size", value: "18")
    // The surviving directive keeps the LAST occurrence's position (last wins),
    // earlier duplicates are dropped, and other directives keep their order.
    #expect(c.ghostty == [
        GhosttyDirective(key: "cursor-style", value: "bar"),
        GhosttyDirective(key: "font-size", value: "18"),
    ])
}

@Test func settingGhosttyNilRemovesAllOccurrences() {
    let c = AppConfig(ghostty: [
        GhosttyDirective(key: "font-size", value: "12"),
        GhosttyDirective(key: "cursor-style", value: "bar"),
        GhosttyDirective(key: "font-size", value: "16"),
    ]).settingGhostty(key: "font-size", value: nil)
    #expect(c.ghostty == [GhosttyDirective(key: "cursor-style", value: "bar")])
    // Removing an absent key is a no-op.
    #expect(c.settingGhostty(key: "font-family", value: nil).ghostty == c.ghostty)
}

@Test func settingGhosttyRoundTripsThroughRenderAndParse() {
    let c = AppConfig()
        .settingGhostty(key: "font-family", value: "JetBrains Mono")
        .settingGhostty(key: "font-size", value: "15")
    let reparsed = AppConfig.parse(c.rendered())
    #expect(reparsed.ghosttyValue("font-family") == "JetBrains Mono")
    #expect(reparsed.ghosttyValue("font-size") == "15")
}

@Test func configParsesCheckUpdates() {
    #expect(AppConfig.parse("").checkUpdates == true)            // default on
    #expect(AppConfig.parse("check-updates = false").checkUpdates == false)
    #expect(AppConfig.parse("check-updates = true").checkUpdates == true)
    // Round-trips through the serialized default.
    #expect(AppConfig.parse(AppConfig(checkUpdates: false).rendered()).checkUpdates == false)
}

@Test func configParsesHibernateAfter() {
    #expect(AppConfig.parse("").hibernateAfter == 0)
    #expect(AppConfig.parse("hibernate-after = 60m").hibernateAfter == 3600)
    #expect(AppConfig.parse("hibernate-after = 2h").hibernateAfter == 7200)
    #expect(AppConfig.parse("hibernate-after = 90").hibernateAfter == 90)
    #expect(AppConfig.parse("hibernate-after = off").hibernateAfter == 0)
    #expect(AppConfig.parse("hibernate-after = garbage").hibernateAfter == 0)
    #expect(AppConfig.parse(AppConfig(hibernateAfter: 3600).rendered()).hibernateAfter == 3600)
}

// MARK: - zetty-tiles-grid (withdrawn)

@Test func theWithdrawnTilesGridKeyIsStillNotForwardedToGhostty() {
    // The key is gone — a view starts as one slot and is split, so there is no
    // default shape to seed — but an existing config still carries the line.
    // It must be SWALLOWED, never forwarded: libghostty validates
    // all-or-nothing, so one unknown key frees the WHOLE config including each
    // pane's `command`, which strands preserved sessions in plain shells.
    //
    // Nothing had to be added to `retiredReservedKeys` for that: the key is in
    // the `zetty-` namespace, and `isReservedButUnsupported` swallows the whole
    // prefix. That is exactly why new keys must use it.
    let config = AppConfig.parse("zetty-tiles-grid = 3x3")
    #expect(config.ghostty.contains { $0.key == "zetty-tiles-grid" } == false)
    #expect(AppConfig.isReservedButUnsupported("zetty-tiles-grid"))
    #expect(config.unsupportedKeys.contains("zetty-tiles-grid"))
}

@Test func theWithdrawnTilesGridKeyIsDroppedOnAPersist() {
    // Rendered output no longer carries it, so the line disappears the first
    // time the config is written back.
    let config = AppConfig.parse("zetty-tiles-grid = 3x3")
    #expect(!config.rendered().contains("zetty-tiles-grid"))
}
