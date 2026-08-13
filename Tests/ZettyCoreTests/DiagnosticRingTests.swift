import XCTest
@testable import ZettyCore

final class DiagnosticRingTests: XCTestCase {

    func testKeepsLinesOldestFirst() {
        let ring = DiagnosticRing()
        ring.append(category: "viewer", message: "first", isError: false)
        ring.append(category: "viewer", message: "second", isError: false)

        let lines = ring.snapshot()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("viewer  first"))
        XCTAssertTrue(lines[1].hasSuffix("viewer  second"))
    }

    func testMarksErrorsForScanning() {
        let ring = DiagnosticRing()
        ring.append(category: "viewer", message: "fine", isError: false)
        ring.append(category: "viewer", message: "broken", isError: true)

        XCTAssertFalse(ring.snapshot()[0].contains("!"))
        XCTAssertTrue(ring.snapshot()[1].contains("!"))
    }

    /// The tail is bounded, and it's the OLDEST lines that go — a report is
    /// filed about what just happened.
    func testDropsOldestPastCapacity() {
        let ring = DiagnosticRing(capacity: 3)
        for index in 1...5 {
            ring.append(category: "viewer", message: "line \(index)", isError: false)
        }

        let lines = ring.snapshot()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("line 3"))
        XCTAssertTrue(lines[2].hasSuffix("line 5"))
    }

    func testStampsEachLineWithAWallClockTime() {
        let ring = DiagnosticRing()
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 13
        components.hour = 15
        components.minute = 36
        components.second = 37
        let date = Calendar(identifier: .gregorian).date(from: components)!

        ring.append(category: "viewer", message: "peek", isError: false, at: date)
        XCTAssertTrue(ring.snapshot()[0].hasPrefix("15:36:37."))
    }

    /// Writers are any thread — the viewer's file load runs off-main — so
    /// concurrent appends must neither crash nor lose lines.
    func testSurvivesConcurrentWriters() {
        let ring = DiagnosticRing(capacity: 1000)
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            ring.append(category: "viewer", message: "line \(index)", isError: false)
        }
        XCTAssertEqual(ring.snapshot().count, 500)
    }
}
