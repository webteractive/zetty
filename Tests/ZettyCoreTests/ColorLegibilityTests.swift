import XCTest
@testable import ZettyCore

final class ColorLegibilityTests: XCTestCase {

    // The scheme backgrounds these cases are checked against.
    private let lightBg1 = (red: 1.0, green: 1.0, blue: 1.0)          // Daylight  #ffffff
    private let sakuraBg1 = (red: 250.0 / 255, green: 244.0 / 255, blue: 237.0 / 255)  // Sakura #faf4ed
    private let darkBg1 = (red: 0x2d / 255.0, green: 0x2a / 255.0, blue: 0x2e / 255.0) // Monokai #2d2a2e

    func testContrastRatioEndpoints() {
        let black = (red: 0.0, green: 0.0, blue: 0.0)
        let white = (red: 1.0, green: 1.0, blue: 1.0)
        XCTAssertEqual(ColorLegibility.contrastRatio(foreground: black, background: white),
                       21, accuracy: 0.01)
        XCTAssertEqual(ColorLegibility.contrastRatio(foreground: white, background: white),
                       1, accuracy: 0.001)
    }

    /// The reported bug: `bat` defaults to a dark theme and emits xterm 231 —
    /// pure white — for ordinary body text. On a light scheme that is invisible,
    /// so the peek reads as an empty panel rather than a mis-coloured one.
    func testBatDefaultBodyWhiteIsIllegibleOnLightSchemes() {
        let xterm231 = (red: 1.0, green: 1.0, blue: 1.0)
        XCTAssertFalse(ColorLegibility.isLegible(foreground: xterm231, background: lightBg1))
        XCTAssertFalse(ColorLegibility.isLegible(foreground: xterm231, background: sakuraBg1))
    }

    func testSameWhiteIsLegibleOnDarkSchemes() {
        let xterm231 = (red: 1.0, green: 1.0, blue: 1.0)
        XCTAssertTrue(ColorLegibility.isLegible(foreground: xterm231, background: darkBg1))
    }

    /// The guard must not flatten a correctly-themed palette: dim comment greys
    /// are meant to be quiet, and recolouring them to `fg` would destroy the
    /// highlighting it exists to protect.
    func testDimButVisibleCommentsSurvive() {
        let comment = (red: 0x72 / 255.0, green: 0x70 / 255.0, blue: 0x72 / 255.0)  // Monokai comment
        XCTAssertTrue(ColorLegibility.isLegible(foreground: comment, background: darkBg1))

        let lightComment = (red: 0x93 / 255.0, green: 0xa1 / 255.0, blue: 0xa1 / 255.0)  // Solarized
        XCTAssertTrue(ColorLegibility.isLegible(foreground: lightComment, background: lightBg1))
    }

    func testTextMatchingTheBackgroundExactlyIsIllegible() {
        XCTAssertFalse(ColorLegibility.isLegible(foreground: darkBg1, background: darkBg1))
        XCTAssertFalse(ColorLegibility.isLegible(foreground: sakuraBg1, background: sakuraBg1))
    }

    func testRatioIsSymmetric() {
        let a = (red: 0.2, green: 0.4, blue: 0.9)
        let b = (red: 0.95, green: 0.95, blue: 0.9)
        XCTAssertEqual(ColorLegibility.contrastRatio(foreground: a, background: b),
                       ColorLegibility.contrastRatio(foreground: b, background: a),
                       accuracy: 0.0001)
    }
}
