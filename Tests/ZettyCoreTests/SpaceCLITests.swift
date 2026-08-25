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
