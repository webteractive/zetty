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

