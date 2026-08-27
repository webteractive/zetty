import XCTest
@testable import ZettyCore

/// Guards the values Zetty renders into ghostty `env` directives.
///
/// libghostty validates its config ALL-OR-NOTHING: one directive it rejects
/// frees the whole config, including the per-surface `command` that attaches a
/// preserved zmx session. Env values now come from user-facing places (project
/// settings, account directories), so they are validated before they can reach
/// `SurfaceRegistry.pair(for:)` rather than trusted at spawn.
final class EnvDirectiveTests: XCTestCase {

    func testAcceptsOrdinaryPairs() {
        XCTAssertTrue(EnvDirective.isValid(key: "CLAUDE_CONFIG_DIR",
                                           value: "/Users/x/.zetty/accounts/work"))
        XCTAssertTrue(EnvDirective.isValid(key: "FOO", value: "bar baz"))
    }

    func testRejectsEmptyKeyOrValue() {
        XCTAssertFalse(EnvDirective.isValid(key: "", value: "v"))
        XCTAssertFalse(EnvDirective.isValid(key: "   ", value: "v"))
        XCTAssertFalse(EnvDirective.isValid(key: "K", value: ""))
        XCTAssertFalse(EnvDirective.isValid(key: "K", value: "   "))
    }

    /// A directive renders as `"\(key) = \(value)"` on ONE line, so a newline in
    /// either half is config injection, not merely a parse error.
    func testRejectsNewlinesAndCarriageReturns() {
        XCTAssertFalse(EnvDirective.isValid(key: "K", value: "a\nb"))
        XCTAssertFalse(EnvDirective.isValid(key: "K", value: "a\r\nb"))
        XCTAssertFalse(EnvDirective.isValid(key: "K\n", value: "v"))
        XCTAssertFalse(EnvDirective.isValid(key: "K", value: "a\rb"))
    }

    func testRejectsControlCharacters() {
        XCTAssertFalse(EnvDirective.isValid(key: "K", value: "a\u{0}b"))
        XCTAssertFalse(EnvDirective.isValid(key: "K", value: "a\tb"))
        XCTAssertFalse(EnvDirective.isValid(key: "K", value: "a\u{7F}b"))
    }

    /// ghostty splits an `env` value on its FIRST `=`, so a key containing one
    /// silently lands part of the key in the value.
    func testRejectsEqualsInKey() {
        XCTAssertFalse(EnvDirective.isValid(key: "A=B", value: "v"))
        XCTAssertTrue(EnvDirective.isValid(key: "A", value: "B=C"))
    }

    func testSanitizedDropsOnlyTheBadPairs() {
        let sanitized = EnvDirective.sanitized([
            "GOOD": "/tmp/ok",
            "BAD": "a\nb",
            "ALSO_GOOD": "x",
            "EMPTY": "",
        ])
        XCTAssertEqual(sanitized, ["GOOD": "/tmp/ok", "ALSO_GOOD": "x"])
    }

    func testSanitizedIsIdentityOnCleanInput() {
        let env = ["A": "1", "B": "2"]
        XCTAssertEqual(EnvDirective.sanitized(env), env)
    }
}
