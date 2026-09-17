import Testing
@testable import ZettyCore

@Test func applicationSupportDirectoryIsTheSharedZettyFolder() {
    let dir = ZettyPaths.applicationSupportDirectory(home: "/Users/tester")
    #expect(dir.path == "/Users/tester/Library/Application Support/zetty")
}

@Test func cliRecognizesTheRunVerb() {
    #expect(ControlCLI.recognizes(["run"]))
    #expect(ControlCLI.recognizes(["run", "personal"]))
    #expect(!ControlCLI.recognizes(["nonesuch"]))
}

@Test func cliRecognizesVersionInAllThreeSpellings() {
    #expect(ControlCLI.recognizes(["--version"]))
    #expect(ControlCLI.recognizes(["-v"]))
    #expect(ControlCLI.recognizes(["version"]))
}

@Test func versionLineCombinesVersionAndCommit() {
    #expect(ControlCLI.versionLine(version: "0.1.44", commit: "cc143c7")
        == "zetty 0.1.44 (cc143c7)")
    // No commit stamp available (standalone swift build) — still a valid answer.
    #expect(ControlCLI.versionLine(version: "0.1.44", commit: nil) == "zetty 0.1.44")
}
