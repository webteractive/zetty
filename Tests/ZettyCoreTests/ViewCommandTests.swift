import Foundation
import Testing
@testable import ZettyCore

@Test func viewRequestRoundTripsThroughJSON() throws {
    let request = ControlRequest.viewFile(path: "/work/a.swift", line: 412, column: 9)
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ControlRequest.self, from: data)
    #expect(decoded == request)
}

@Test func viewRequestRoundTripsWithoutAPosition() throws {
    let request = ControlRequest.viewFile(path: "/work/a.swift", line: nil, column: nil)
    let data = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
}

@Test func viewIsARecognizedCLICommand() {
    #expect(ControlCLI.recognizes(["view"]))
}

@Test func usageDocumentsView() {
    #expect(ControlCLI.usage.contains("zetty view"))
}

// The path:line:col splitting the CLI relies on is `FilePathToken.parse`,
// already covered by FilePathTokenTests; these pin the CLI-facing cases.

@Test func parseHandlesAnAbsolutePathWithPosition() {
    #expect(FilePathToken.parse("/work/a.swift:412:9")
            == PathToken(path: "/work/a.swift", line: 412, column: 9))
}

@Test func parseHandlesAPathContainingAColon() {
    #expect(FilePathToken.parse("/work/weird:name.swift:12")
            == PathToken(path: "/work/weird:name.swift", line: 12))
}
