import Foundation
import Testing
@testable import ZettyCore

// MARK: - Config parsing

@Test func homePathDefaultsToUnset() {
    #expect(AppConfig.parse("").homePath == nil)
}

@Test func homePathParses() {
    #expect(AppConfig.parse("zetty-home-path = /Users/x/Projects").homePath == "/Users/x/Projects")
}

/// `off`/`default`/`~` all mean "the real home directory", i.e. unset. An empty
/// VALUE can't reach the switch (the parser skips empty values), so these words
/// are the documented way to go back to the default.
@Test func homePathWordsMeaningDefaultClearTheOverride() {
    for value in ["off", "none", "default", "~"] {
        #expect(AppConfig.parse("zetty-home-path = \(value)").homePath == nil)
    }
}

@Test func homePathIsNeverForwardedToGhostty() {
    let config = AppConfig.parse("zetty-home-path = /Users/x/Projects")
    #expect(config.ghostty.isEmpty)
    #expect(config.unsupportedKeys.isEmpty)
}

@Test func homePathSurvivesARuntimePersist() {
    let config = AppConfig.parse("zetty-home-path = /Users/x/Projects")
    #expect(AppConfig.parse(config.rendered()).homePath == "/Users/x/Projects")
}

/// An unset override must not re-emit a value that would pin Home to `~`
/// literally — the key stays commented out so the default keeps following the
/// account's home directory.
@Test func renderedOmitsAnUnsetHomePath() {
    #expect(AppConfig.parse(AppConfig().rendered()).homePath == nil)
}

// MARK: - Resolution

@Test func resolvedHomePathFallsBackToTheRealHome() {
    #expect(AppConfig().resolvedHomePath(defaultHome: "/Users/x") == "/Users/x")
}

@Test func resolvedHomePathExpandsLeadingTilde() {
    var config = AppConfig()
    config.homePath = "~/Projects"
    #expect(config.resolvedHomePath(defaultHome: "/Users/x") == "/Users/x/Projects")
}

/// A `~` that isn't a path component (`~backup`) is a real directory name, not
/// a home reference — `expandingTildeInPath` would mangle it into another
/// user's home.
@Test func resolvedHomePathLeavesAnInteriorOrBareTildeAlone() {
    var config = AppConfig()
    config.homePath = "/srv/~backup"
    #expect(config.resolvedHomePath(defaultHome: "/Users/x") == "/srv/~backup")
    config.homePath = "~backup"
    #expect(config.resolvedHomePath(defaultHome: "/Users/x") == "~backup")
}

@Test func resolvedHomePathStripsATrailingSlash() {
    var config = AppConfig()
    config.homePath = "/Users/x/Projects/"
    #expect(config.resolvedHomePath(defaultHome: "/Users/x") == "/Users/x/Projects")
    // ...but "/" is still a valid root.
    config.homePath = "/"
    #expect(config.resolvedHomePath(defaultHome: "/Users/x") == "/")
}

// MARK: - Model

@Test func makeHomeTakesARootOverride() {
    let home = WorkspaceModel.makeHome(rootPath: "/Users/x/Projects")
    #expect(home.isHome)
    #expect(home.rootPath == "/Users/x/Projects")
}

@Test func homeRootSeedsWhereItsTabsOpen() {
    let ws = WorkspaceModel(homeRoot: "/Users/x/Projects")
    #expect(ws.projects[0].rootPath == "/Users/x/Projects")
    #expect(ws.projects[0].tabList.trees[0].layout.surfaces.first?.workingDir == "/Users/x/Projects")
}

/// The config is the single source of truth: a Home persisted at the old path
/// is re-rooted on restore rather than pinning the workspace to it forever.
@Test func restoredReRootsAPersistedHome() {
    let ws = WorkspaceModel.restored(from: [
        ProjectRuntime(name: "Home", rootPath: "/Users/x", isHome: true),
        ProjectRuntime(name: "api", rootPath: "/Users/x/api"),
    ], activeIndex: 0, homeRoot: "/Users/x/Projects")!
    #expect(ws.projects.filter(\.isHome).count == 1)
    #expect(ws.projects[0].rootPath == "/Users/x/Projects")
    #expect(ws.projects[1].rootPath == "/Users/x/api")   // other projects untouched
}

/// The same path back: dropping the override re-roots Home to the real home.
@Test func restoredReRootsHomeBackToTheDefault() {
    let ws = WorkspaceModel.restored(from: [
        ProjectRuntime(name: "Home", rootPath: "/Users/x/Projects", isHome: true),
    ], activeIndex: 0, homeRoot: "/Users/x")!
    #expect(ws.projects[0].rootPath == "/Users/x")
}

@Test func restoredInjectsHomeAtTheConfiguredRoot() {
    let ws = WorkspaceModel.restored(from: [
        ProjectRuntime(name: "api", rootPath: "/Users/x/api"),
    ], activeIndex: 0, homeRoot: "/Users/x/Projects")!
    #expect(ws.projects[0].isHome)
    #expect(ws.projects[0].rootPath == "/Users/x/Projects")
}

/// ⇧⌘, reload: the next tab must open in the new root. Re-rooting that forgot
/// the tab list's default working dir would leave new tabs in the old place —
/// the whole point of the feature.
@Test func setHomeRootMovesWhereTheNextTabOpens() {
    let ws = WorkspaceModel(homeRoot: "/Users/x")
    ws.setHomeRoot("/Users/x/Projects")
    #expect(ws.projects[0].rootPath == "/Users/x/Projects")
    ws.projects[0].tabList.newTab()
    #expect(ws.projects[0].tabList.trees.last?.layout.surfaces.first?.workingDir == "/Users/x/Projects")
}

/// Existing panes keep their own working dirs — a live shell's cwd is its own,
/// and a preserved session captured it at creation.
@Test func setHomeRootLeavesExistingPanesAlone() {
    let ws = WorkspaceModel(homeRoot: "/Users/x")
    ws.setHomeRoot("/Users/x/Projects")
    #expect(ws.projects[0].tabList.trees[0].layout.surfaces.first?.workingDir == "/Users/x")
}

@Test func setHomeRootIgnoresANonHomeProject() {
    let ws = WorkspaceModel(homeRoot: "/Users/x")
    let api = ws.addProject(name: "api", rootPath: "/Users/x/api")
    ws.setHomeRoot("/Users/x/Projects")
    #expect(api.rootPath == "/Users/x/api")
}

/// Home's settings live under the `@home` sentinel, so pointing Home at a
/// directory a user project also uses can't merge their settings.
@Test func aCustomHomeRootStillKeepsTheHomeSettingsKey() {
    let ws = WorkspaceModel(homeRoot: "/Users/x/Projects")
    #expect(ws.projects[0].settingsKey == ProjectSettingsStore.homeKey)
}

// MARK: - Writing the value back (Home's Project Settings picker)

@Test func homePathValueAbbreviatesInsideHome() {
    #expect(AppConfig.homePathValue(for: "/Users/x/Projects", defaultHome: "/Users/x") == "~/Projects")
}

@Test func homePathValueKeepsAPathOutsideHomeAbsolute() {
    #expect(AppConfig.homePathValue(for: "/Volumes/work", defaultHome: "/Users/x") == "/Volumes/work")
    // A sibling account's home shares the prefix but isn't inside it.
    #expect(AppConfig.homePathValue(for: "/Users/xavier", defaultHome: "/Users/x") == "/Users/xavier")
}

/// Picking the home directory itself means "no override" — the key is dropped
/// rather than written out, so Home keeps following the account's home.
@Test func homePathValueClearsWhenPickingTheHomeDirectory() {
    #expect(AppConfig.homePathValue(for: "/Users/x", defaultHome: "/Users/x") == nil)
    #expect(AppConfig.homePathValue(for: "/Users/x/", defaultHome: "/Users/x") == nil)
    #expect(AppConfig.homePathValue(for: "  ", defaultHome: "/Users/x") == nil)
}

/// The picker writes what the resolver reads: a round-trip must land on the
/// directory the user actually chose.
@Test func homePathValueRoundTripsThroughTheResolver() {
    for picked in ["/Users/x/Projects", "/Volumes/work", "/Users/x"] {
        var config = AppConfig()
        config.homePath = AppConfig.homePathValue(for: picked, defaultHome: "/Users/x")
        #expect(config.resolvedHomePath(defaultHome: "/Users/x") == picked)
    }
}
