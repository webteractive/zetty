// SurfaceRegistryTests.swift — Task 2
//
// Verifies SurfaceRegistry bookkeeping via the TerminalControlling protocol
// seam, so no real ghostty PTY/display is needed during unit tests.

import XCTest
import ZettyCore
@testable import ZettyGhostty

// MARK: - Mocks

/// A lightweight stand-in that satisfies `TerminalControlling` without
/// touching libghostty.
final class MockTerminalController: TerminalControlling {}

/// A counting NSView subclass used to verify that the view factory is called
/// exactly once per live surface (and again after pruning).
final class CountingView: NSView {
    static var creationCount = 0
    override init(frame: NSRect) {
        CountingView.creationCount += 1
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not used in tests") }
}

// MARK: - Tests

/// `@MainActor` because `SurfaceRegistry` is `@MainActor` (its default
/// factory creates `TerminalController`, which requires the main actor).
@MainActor
final class SurfaceRegistryTests: XCTestCase {

    func testReusesControllerForSameSurfaceID() {
        let reg = SurfaceRegistry(
            controllerFactory: { _ in MockTerminalController() }
        )
        let s = Surface(workingDir: "/tmp")
        let a = reg.controller(for: s)
        let b = reg.controller(for: s)
        XCTAssertTrue(
            ObjectIdentifier(a as AnyObject) == ObjectIdentifier(b as AnyObject),
            "registry must return the same instance on second call"
        )
        XCTAssertEqual(reg.liveIDs, [s.id])
    }

    func testPruneTearsDownAbsentSurfaces() {
        let reg = SurfaceRegistry(
            controllerFactory: { _ in MockTerminalController() }
        )
        let s1 = Surface(workingDir: "/tmp")
        let s2 = Surface(workingDir: "/tmp")
        _ = reg.controller(for: s1)
        _ = reg.controller(for: s2)
        reg.prune(keeping: [s1.id])
        XCTAssertEqual(reg.liveIDs, [s1.id])
    }

    // MARK: - View-preservation invariant (Task 3)

    /// The central invariant of Task 3: `terminalView(for:)` must return the
    /// *same* NSView instance on every call for the same surface so that the
    /// live PTY (which lives inside the view) is never destroyed by a re-render.
    /// After `prune(keeping:[])` the old view is released and the next call
    /// must produce a *new* view (factory counter increments).
    func testTerminalViewIsPreservedAcrossRepeatedCalls() {
        CountingView.creationCount = 0
        let reg = SurfaceRegistry(
            controllerFactory: { _ in MockTerminalController() },
            viewFactory: { _, _ in (CountingView(frame: .zero), nil) }
        )
        let s = Surface(workingDir: "/tmp")

        // First call creates one view.
        let v1 = reg.terminalView(for: s)
        XCTAssertEqual(CountingView.creationCount, 1, "factory should be called exactly once on first access")

        // Repeated call must return the identical object — not a new one.
        let v2 = reg.terminalView(for: s)
        XCTAssertTrue(v1 === v2, "registry must return the same NSView instance on repeated calls for the same surface")
        XCTAssertEqual(CountingView.creationCount, 1, "factory must not be called again for an already-registered surface")

        // After pruning, the next call must create a fresh view.
        reg.prune(keeping: [])
        _ = reg.terminalView(for: s)
        XCTAssertEqual(CountingView.creationCount, 2, "factory must create a new view after the old one was pruned")
    }

    func testNewSurfaceAfterPruneGetsNewController() {
        let reg = SurfaceRegistry(
            controllerFactory: { _ in MockTerminalController() }
        )
        let s = Surface(workingDir: "/tmp")
        let first = reg.controller(for: s)
        reg.prune(keeping: [])
        // After pruning the registry is empty, so the next call creates a new one.
        let second = reg.controller(for: s)
        XCTAssertFalse(
            ObjectIdentifier(first as AnyObject) == ObjectIdentifier(second as AnyObject),
            "pruned entry must not be reused"
        )
    }
}
