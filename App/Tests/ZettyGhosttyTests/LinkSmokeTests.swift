// LinkSmokeTests.swift — Task 5 smoke test
//
// Verifies that:
//   1. The ZettyGhostty module links (import succeeds).
//   2. `ghostty_init(0, nil)` returns 0 and sets `Ghostty.isInitialized`.
//
// Uses XCTest (not Swift Testing) — XCTest discovery is robust under
// Tuist-generated projects + xcodebuild, avoiding Swift Testing's extra
// discovery configuration.

import XCTest
@testable import ZettyGhostty

final class LinkSmokeTests: XCTestCase {
    func testRuntimeInitializesWithoutThrowing() throws {
        try Ghostty.initializeRuntime()
        XCTAssertTrue(Ghostty.isInitialized)
    }

    func testDoubleInitIsIdempotent() throws {
        try Ghostty.initializeRuntime()
        try Ghostty.initializeRuntime()  // second call should be a no-op
        XCTAssertTrue(Ghostty.isInitialized)
    }
}
