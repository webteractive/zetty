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
    // Reserved keys stay quertty's; everything else is forwarded verbatim.
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
        .appendingPathComponent("quertty-config-test-\(UUID().uuidString)", isDirectory: true)
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
        .appendingPathComponent("quertty-config-save-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("config")
    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

    let store = ConfigStore(fileURL: tmp)
    let config = AppConfig(appearance: .dark, themeDark: "Frost", themeLight: "Paper")
    store.save(config)
    #expect(store.load() == config)
}
