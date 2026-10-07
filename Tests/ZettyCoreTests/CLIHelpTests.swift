import Foundation
import Testing
@testable import ZettyCore

/// `--help` must never act. `zetty scratch-clear --help` once ignored the flag
/// and cleared every scratch terminal on the machine of an agent that was only
/// reading the usage; `quit --help` would have quit the app.

/// Arguments that would make each verb DO something if `--help` were ignored.
/// Every verb in `ControlCLI.verbs` must appear: a new verb without an entry
/// fails `everyVerbHasRealisticArguments`.
private let actingArguments: [String: [String]] = [
    "status": ["--json"],
    "ls": [],
    "send": ["--pane", "abcd1234", "echo", "hi", "--enter"],
    "capture": ["--pane", "abcd1234", "--lines", "5"],
    "view": ["/tmp/zetty-help-test.txt:3"],
    "new-tab": ["--project", "Foo", "--focus"],
    "add-project": ["/tmp"],
    "new-project": ["/tmp/zetty-help-test-must-not-exist"],
    "clone": ["--project", "Foo"],
    "update-clone": ["Foo"],
    "merge-clone": ["Foo"],
    "push-clone": ["Foo"],
    "remove-project": ["Foo", "--discard"],
    "hibernate": ["Foo", "--no-handoff"],
    "wake": ["--space", "Work"],
    "split": ["--pane", "abcd1234", "--focus"],
    "break": ["--pane", "abcd1234"],
    "focus": ["--pane", "abcd1234"],
    "close": ["--pane", "abcd1234", "--tab"],
    "reload": [],
    "tiles": ["open", "Generic"],
    "scratch": ["--focus"],
    "scratch-clear": [],
    "quit": ["--kill-sessions"],
    "accounts": ["--probe"],
    // Everything after `run`'s account name belongs to the harness (see
    // `runAccountPassesHelpThrough`), so its acting form is the bare verb.
    "run": [],
    "new-space": ["Foo"],
    "rename-space": ["Old", "New"],
    "remove-space": ["Foo"],
    "move-to-space": ["Foo", "Work"],
]

@Test func everyVerbHasRealisticArguments() {
    for verb in ControlCLI.verbs {
        #expect(actingArguments[verb] != nil, "add acting arguments for \(verb)")
    }
}

@Test(arguments: ControlCLI.verbs)
func helpNeverReachesTheApp(verb: String) {
    let args = actingArguments[verb] ?? []
    // Bare, after the arguments, before them, and in the short form.
    let forms: [[String]] = [
        [verb, "--help"],
        [verb] + args + ["--help"],
        [verb, "--help"] + args,
        [verb] + args + ["-h"],
    ]
    for form in forms {
        let (exit, recorder) = runIsolated(form)
        #expect(recorder.requests.isEmpty, "\(form.joined(separator: " ")) sent \(recorder.requests)")
        #expect(exit == 0, "\(form.joined(separator: " ")) exited \(exit)")
        // Its OWN help, not the whole usage dump.
        #expect(recorder.output.contains("zetty \(verb == "ls" ? "status" : verb)"),
                "\(form.joined(separator: " ")) printed no help for \(verb)")
        #expect(recorder.output != ControlCLI.usage + "\n")
    }
    #expect(!FileManager.default.fileExists(atPath: "/tmp/zetty-help-test-must-not-exist"))
}

@Test func tilesSubcommandHelpNeverReachesTheApp() {
    for form in [["tiles", "delete", "Generic", "--help"], ["tiles", "detach", "--slot", "1", "-h"],
                 ["tiles", "--off", "--help"], ["tiles", "list", "--help"]] {
        let (exit, recorder) = runIsolated(form)
        #expect(recorder.requests.isEmpty, "\(form) sent \(recorder.requests)")
        #expect(exit == 0)
        #expect(recorder.output.contains("zetty tiles"))
    }
}

@Test func runAccountPassesHelpThrough() {
    // `zetty run work --help` means "show the harness's help" — that is the
    // contract of `run`. With an account that cannot exist it fails before
    // any exec, and it must not have told the app anything either.
    let (exit, recorder) = runIsolated(["run", "no-such-account-\(UUID().uuidString)", "--help"])
    #expect(exit != 0)
    #expect(recorder.requests.isEmpty)
}

@Test func theTransportSeamDoesCatchARealCommand() {
    // Guards the tests above: if the seam were bypassed they would pass
    // vacuously.
    let (_, recorder) = runIsolated(["scratch-clear"])
    #expect(recorder.requests == [.scratchClear(force: false)])
}
