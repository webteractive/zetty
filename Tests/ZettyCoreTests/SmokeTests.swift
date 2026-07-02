// Tests/ZettyCoreTests/SmokeTests.swift
import Testing
@testable import ZettyCore

@Test func moduleHasVersion() {
    #expect(ZettyCore.version == "0.0.1")
}
