import Testing
@testable import ZettyCore

private let a = PaneRecord(pane: "aaaa0001", project: "web", cwd: "/w")
private let b = PaneRecord(pane: "bbbb0002", project: "web", cwd: "/w")
private let c = PaneRecord(pane: "cccc0003", project: "api", cwd: nil)

@Test func trackerFirstUpdateIsABaseline() {
    #expect(PaneEventTracker().update(panes: [a, b], activeProject: "web", emitPaneChanges: true).isEmpty)
}

@Test func trackerReportsClosedThenOpenedThenFocus() {
    let tracker = PaneEventTracker()
    _ = tracker.update(panes: [a, b], activeProject: "web", emitPaneChanges: true)
    #expect(tracker.update(panes: [a, c], activeProject: "api", emitPaneChanges: true) == [
        .paneClosed(pane: "bbbb0002", project: "web"),
        .paneOpened(c),
        .projectFocused(project: "api", previous: "web"),
    ])
}

@Test func trackerIgnoresUnchangedAndCwdOnlyChanges() {
    let tracker = PaneEventTracker()
    _ = tracker.update(panes: [a], activeProject: "web", emitPaneChanges: true)
    var moved = a
    moved.cwd = "/elsewhere"
    #expect(tracker.update(panes: [moved], activeProject: "web", emitPaneChanges: true).isEmpty)
}

@Test func scriptChordParsesPrefixLayerKeysOnly() {
    #expect(ScriptBinding.chord("prefix>d") == KeyChord.parse("d")?.normalized)
    #expect(ScriptBinding.chord("d") == KeyChord.parse("d")?.normalized)
    #expect(ScriptBinding.chord("prefx>d") == nil)
    #expect(ScriptBinding.chord("") == nil)
    #expect(ScriptBinding.chord("prefix>") == nil)
    #expect(ScriptBinding.chord("prefix>>") == KeyChord.parse(">")?.normalized)
}

@Test func trackerAbsorbsChangesWithoutEmitting() {
    let tracker = PaneEventTracker()
    _ = tracker.update(panes: [a], activeProject: "web", emitPaneChanges: true)
    #expect(tracker.update(panes: [a, b], activeProject: "web", emitPaneChanges: false).isEmpty)
    #expect(tracker.update(panes: [a, b], activeProject: "web", emitPaneChanges: true).isEmpty)
}

/// The spec carves out pane events only: a project switch a script made
/// (say, from the user's own key action) still reaches project.focused.
@Test func trackerReportsFocusEvenWhenAbsorbingPaneChanges() {
    let tracker = PaneEventTracker()
    _ = tracker.update(panes: [a], activeProject: "web", emitPaneChanges: true)
    #expect(tracker.update(panes: [a, c], activeProject: "api", emitPaneChanges: false)
        == [.projectFocused(project: "api", previous: "web")])
}
