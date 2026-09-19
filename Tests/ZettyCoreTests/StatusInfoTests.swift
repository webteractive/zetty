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

    func testStaysWideWhileTheAmbientGroupFits() {
        XCTAssertFalse(StatusBarCompaction.isCompact(available: 400, required: 300, wasCompact: false))
    }

    func testCollapsesWhenTheAmbientGroupNoLongerFits() {
        XCTAssertTrue(StatusBarCompaction.isCompact(available: 299, required: 300, wasCompact: false))
    }

    func testAnExactFitStaysWide() {
        XCTAssertFalse(StatusBarCompaction.isCompact(available: 300, required: 300, wasCompact: false))
    }

    func testStaysCompactInsideTheHysteresisBand() {
        // Re-expanding the moment it fits again would flap the whole right
        // cluster back and forth while the window is dragged across the edge.
        let justOver = 300 + StatusBarCompaction.hysteresis - 1
        XCTAssertTrue(StatusBarCompaction.isCompact(available: justOver, required: 300, wasCompact: true))
    }

    func testExpandsOnceClearOfTheHysteresisBand() {
        let clear = 300 + StatusBarCompaction.hysteresis
        XCTAssertFalse(StatusBarCompaction.isCompact(available: clear, required: 300, wasCompact: true))
    }

    func testNothingToShowIsNeverCompact() {
        // An empty ambient group needs no chip standing in for it.
        XCTAssertFalse(StatusBarCompaction.isCompact(available: 0, required: 0, wasCompact: true))
    }

    func testNegativeSpaceIsCompact() {
        // Mid-resize the leftover can be reported negative; treat it as no room.
        XCTAssertTrue(StatusBarCompaction.isCompact(available: -20, required: 300, wasCompact: false))
    }
}
