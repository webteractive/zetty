import XCTest
@testable import ZettyCore

// MARK: - StatusInfoValues

final class StatusInfoValuesTests: XCTestCase {

    private let full = StatusInfoValues(appearance: "System", scheme: "Nord",
                                        shell: "zsh", ghostty: "1.2.3", version: "0.1.45")

    func testPopulatedKeepsDisplayOrder() {
        XCTAssertEqual(full.populated, [.appearance, .scheme, .shell, .ghostty, .version])
    }

    func testPopulatedDropsEmptyValues() {
        let sparse = StatusInfoValues(appearance: "Dark", scheme: "", shell: "fish",
                                      ghostty: "", version: "")
        XCTAssertEqual(sparse.populated, [.appearance, .shell])
    }

    func testPopulatedTreatsWhitespaceAsEmpty() {
        let padded = StatusInfoValues(appearance: "   ", scheme: "Nord")
        XCTAssertEqual(padded.populated, [.scheme])
    }

    func testLabelsDisambiguateTheTwoVersionNumbers() {
        // Bare "1.2.3" next to "0.1.45" in a cycling chip says nothing about
        // which is which, so both carry their product name.
        XCTAssertEqual(full.label(for: .ghostty), "ghostty 1.2.3")
        XCTAssertEqual(full.label(for: .version), "zetty 0.1.45")
    }

    func testLabelsPassTheOthersThroughUnchanged() {
        XCTAssertEqual(full.label(for: .appearance), "System")
        XCTAssertEqual(full.label(for: .scheme), "Nord")
        XCTAssertEqual(full.label(for: .shell), "zsh")
    }

    func testLabelIsEmptyWhenTheValueIs() {
        let none = StatusInfoValues()
        for item in StatusInfoItem.allCases {
            XCTAssertEqual(none.label(for: item), "", "\(item) should not render a bare prefix")
        }
    }
}

// MARK: - StatusBarCompaction

final class StatusBarCompactionTests: XCTestCase {

    private let wide = StatusBarCompaction.compactBelow + 200
    private let narrow = StatusBarCompaction.compactBelow - 1

    func testAWideWindowShowsEverything() {
        XCTAssertFalse(StatusBarCompaction.isCompact(windowWidth: wide, wasCompact: false))
    }

    func testANarrowWindowFolds() {
        XCTAssertTrue(StatusBarCompaction.isCompact(windowWidth: narrow, wasCompact: false))
    }

    func testTheThresholdItselfStaysWide() {
        XCTAssertFalse(StatusBarCompaction.isCompact(
            windowWidth: StatusBarCompaction.compactBelow, wasCompact: false))
    }

    func testStaysCompactInsideTheHysteresisBand() {
        // Re-expanding the moment it fits again would swap the whole bar back
        // and forth while the window is dragged across the edge.
        let justOver = StatusBarCompaction.compactBelow + StatusBarCompaction.hysteresis - 1
        XCTAssertTrue(StatusBarCompaction.isCompact(windowWidth: justOver, wasCompact: true))
    }

    func testExpandsOnceClearOfTheBand() {
        let clear = StatusBarCompaction.compactBelow + StatusBarCompaction.hysteresis
        XCTAssertFalse(StatusBarCompaction.isCompact(windowWidth: clear, wasCompact: true))
    }

    func testAnUnlaidOutViewKeepsItsCurrentLayout() {
        // Width 0 is "not laid out yet", not "as narrow as possible"; treating
        // it as narrow flashes the compact bar on first paint.
        XCTAssertFalse(StatusBarCompaction.isCompact(windowWidth: 0, wasCompact: false))
        XCTAssertTrue(StatusBarCompaction.isCompact(windowWidth: 0, wasCompact: true))
    }

    func testTheLeftClusterFoldsLaterThanTheAmbientStats() {
        // Order matters: the ambient stats are the first thing to go, and the
        // working directory the last.
        XCTAssertLessThan(StatusBarCompaction.collapseLeftBelow,
                          StatusBarCompaction.compactBelow)
    }

    func testTheLeftClusterFoldsOnlyWhenVeryNarrow() {
        let between = (StatusBarCompaction.collapseLeftBelow
            + StatusBarCompaction.compactBelow) / 2
        XCTAssertFalse(StatusBarCompaction.isLeftCollapsed(windowWidth: between,
                                                           wasCollapsed: false))
        XCTAssertTrue(StatusBarCompaction.isLeftCollapsed(
            windowWidth: StatusBarCompaction.collapseLeftBelow - 1, wasCollapsed: false))
    }
}
