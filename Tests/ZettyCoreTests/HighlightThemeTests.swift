import XCTest
@testable import ZettyCore

final class HighlightThemeTests: XCTestCase {

    func testDarkSchemePinsTheDarkTheme() {
        let environment = HighlightTheme.environment(isDark: true)
        XCTAssertEqual(environment["BAT_THEME"], HighlightTheme.darkTheme)
    }

    /// The whole point: on a light scheme the highlighter must NOT fall back to
    /// its dark default, whose near-white body text is invisible on `bg1`.
    func testLightSchemePinsTheLightTheme() {
        let environment = HighlightTheme.environment(isDark: false)
        XCTAssertEqual(environment["BAT_THEME"], HighlightTheme.lightTheme)
        XCTAssertNotEqual(environment["BAT_THEME"], HighlightTheme.darkTheme)
    }

    /// Both axis hints are always set, so a bat build that *can* detect a
    /// background still lands on one of Zetty's chosen themes either way.
    func testBothAxisHintsAreAlwaysSet() {
        for isDark in [true, false] {
            let environment = HighlightTheme.environment(isDark: isDark)
            XCTAssertEqual(environment["BAT_THEME_DARK"], HighlightTheme.darkTheme)
            XCTAssertEqual(environment["BAT_THEME_LIGHT"], HighlightTheme.lightTheme)
        }
    }

    /// The theme entries must not clobber PATH/TERM, which is how the child
    /// finds its own helpers.
    func testMergesOverABaseEnvironmentWithoutDroppingIt() {
        var environment = ["PATH": "/usr/bin", "TERM": "xterm-256color"]
        environment.merge(HighlightTheme.environment(isDark: true)) { _, new in new }
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["BAT_THEME"], HighlightTheme.darkTheme)
    }
}
