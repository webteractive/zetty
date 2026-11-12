import Testing
import Foundation
@testable import ZettyCore

@Test func surfaceCarriesWorkingDirAndCommand() {
    let s = Surface(workingDir: "/tmp/proj", command: "claude")
    #expect(s.workingDir == "/tmp/proj")
    #expect(s.command == "claude")
}

@Test func projectStartsWithNoSessions() {
    let p = Project(name: "demo", rootPath: "/tmp/proj")
    #expect(p.name == "demo")
    #expect(p.sessions.isEmpty)
}
