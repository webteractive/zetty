import Testing
import Foundation
@testable import ZettyCore

@Test func newProjectRejectsEmptyAndWhitespaceNames() {
    #expect(throws: NewProjectRequest.ValidationError.emptyName) {
        try NewProjectRequest.validate(name: "")
    }
    #expect(throws: NewProjectRequest.ValidationError.emptyName) {
        try NewProjectRequest.validate(name: "   ")
    }
}

@Test func newProjectRejectsSeparatorsAndReservedAndHidden() {
    #expect(throws: NewProjectRequest.ValidationError.containsSeparator) {
        try NewProjectRequest.validate(name: "a/b")
    }
    #expect(throws: NewProjectRequest.ValidationError.reservedName) {
        try NewProjectRequest.validate(name: ".")
    }
    #expect(throws: NewProjectRequest.ValidationError.reservedName) {
        try NewProjectRequest.validate(name: "..")
    }
    #expect(throws: NewProjectRequest.ValidationError.leadingDot) {
        try NewProjectRequest.validate(name: ".hidden")
    }
}

@Test func newProjectComposesAndTrimsTargetPath() throws {
    let request = NewProjectRequest(parentPath: "/Users/x/code", name: "  my-proj  ")
    #expect(request.name == "my-proj")
    #expect(try request.targetPath() == "/Users/x/code/my-proj")
}

@Test func newProjectTargetPathThrowsOnInvalidName() {
    #expect(throws: NewProjectRequest.ValidationError.emptyName) {
        try NewProjectRequest(parentPath: "/Users/x", name: " ").targetPath()
    }
}

@Test func cliRecognizesNewProject() {
    #expect(ControlCLI.recognizes(["new-project"]))
}

@Test func cliNewProjectRequiresPath() {
    // Missing path fails BEFORE any socket round-trip → exit 1.
    #expect(ControlCLI.run(["new-project"]) == 1)
}

@Test func cliNewProjectHelpExitsZero() {
    // --help prints usage and returns 0 before any socket round-trip.
    #expect(ControlCLI.run(["new-project", "--help"]) == 0)
}
