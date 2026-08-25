import Testing
import Foundation
@testable import ZettyCore

private func project(_ name: String, space: String? = nil,
                     hibernated: Bool = false) -> StatusSnapshot.Project {
    StatusSnapshot.Project(name: name, isActive: false, hibernated: hibernated,
                           space: space, tabs: [])
}

@Test func statusLinesEmitOneHeaderPerSpace() {
    let snapshot = StatusSnapshot(
        projects: [project("Home"),
                   project("acme-api", space: "Client Acme"),
                   project("acme-web", space: "Client Acme"),
                   project("zetty")],
        spaces: [.init(name: "Client Acme", collapsed: false)]
    )
    let lines = ControlCLI.statusLines(snapshot)
    #expect(lines.filter { $0.contains("[space]") }.count == 1)
    #expect(lines.contains { $0.contains("Client Acme") && $0.contains("[space]") })
    let headerIndex = lines.firstIndex { $0.contains("[space]") }!
    let apiIndex = lines.firstIndex { $0.contains("acme-api") }!
    #expect(headerIndex < apiIndex)
}

@Test func statusLinesShowAnEmptySpace() {
    let snapshot = StatusSnapshot(
        projects: [project("Home")],
        spaces: [.init(name: "Fresh", collapsed: false)]
    )
    let lines = ControlCLI.statusLines(snapshot)
    #expect(lines.contains { $0.contains("Fresh") && $0.contains("[space, empty]") })
}

@Test func statusLinesMarkAHibernatedMemberInPlace() {
    let snapshot = StatusSnapshot(
        projects: [project("acme-api", space: "Client Acme"),
                   project("acme-infra", space: "Client Acme", hibernated: true)],
        spaces: [.init(name: "Client Acme", collapsed: false)]
    )
    let lines = ControlCLI.statusLines(snapshot)
    let infra = lines.first { $0.contains("acme-infra") }!
    #expect(infra.contains("☾"))
    #expect(infra.contains("(hibernated)"))
    // Still inside the Space — no second header between it and its sibling.
    #expect(lines.filter { $0.contains("[space") }.count == 1)
}

@Test func statusLinesOmitSpaceMarkupWhenThereAreNoSpaces() {
    let snapshot = StatusSnapshot(projects: [project("solo")])
    #expect(ControlCLI.statusLines(snapshot).allSatisfy { !$0.contains("[space") })
}

@Test func spaceVerbsAreAdvertised() {
    for verb in ["new-space", "rename-space", "remove-space", "move-to-space"] {
        #expect(ControlCLI.recognizes([verb]))
    }
}

@Test func usageDocumentsTheSpaceVerbsAndFlags() {
    let usage = ControlCLI.usage
    #expect(usage.contains("new-space"))
    #expect(usage.contains("move-to-space"))
    #expect(usage.contains("--none"))
    #expect(usage.contains("--space"))
}

@Test func spaceVerbsReachTheirRunners() {
    // `recognizes(_:)` only proves the verb string is listed. These calls prove
    // the dispatch switch routes each verb to a runner: every one of them fails
    // (or prints usage) BEFORE any socket is opened, so they need no live app.
    #expect(ControlCLI.run(["new-space"]) == 1)                                   // empty name
    #expect(ControlCLI.run(["rename-space", "one"]) == 1)                         // needs both names
    #expect(ControlCLI.run(["remove-space"]) == 1)                                // needs a name
    #expect(ControlCLI.run(["move-to-space"]) == 1)                               // needs a project
    for verb in ["new-space", "rename-space", "remove-space", "move-to-space"] {
        #expect(ControlCLI.run([verb, "--help"]) == 0)
    }
}

@Test func moveToSpaceRejectsANameAndNoneTogether() {
    // The "not both" contract: never a silent precedence between them.
    #expect(ControlCLI.run(["move-to-space", "proj", "Work", "--none"]) == 1)
}

@Test func renameSpaceAcceptsUnquotedMultiWordNamesViaTo() {
    // Regression for the bug this round fixes: `--to` joins a multi-word name
    // on either side of the marker without quoting. Each case here leaves the
    // OTHER side empty on purpose, so the empty-name guard fires and the
    // runner fails before `expectOK` would open the control socket — this
    // machine has a real Zetty app running, and a genuine two-sided call
    // would send it a live renameSpace request its socket handler doesn't
    // implement yet (Task 6 is still pending). That still exercises the
    // exact array-slice-and-join logic this fix touches on both sides.
    #expect(ControlCLI.run(["rename-space", "Client", "Acme", "--to"]) == 1)       // multi-word OLD joins; NEW left blank
    #expect(ControlCLI.run(["rename-space", "--to", "Acme", "Corp"]) == 1)         // multi-word NEW joins; OLD left blank
    // No `--to` marker at all: still rejected as an ambiguous 4-positional call.
    #expect(ControlCLI.run(["rename-space", "Client", "Acme", "New", "Name"]) == 1)
}
