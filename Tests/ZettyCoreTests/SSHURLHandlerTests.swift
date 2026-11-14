import XCTest
@testable import ZettyCore

final class SSHURLHandlerTests: XCTestCase {
    private func cmd(_ s: String) -> String? {
        guard let url = URL(string: s) else { return nil }
        return SSHURLHandler.command(for: url)
    }

    func testBareHost() {
        XCTAssertEqual(cmd("ssh://example.com"), "ssh example.com")
    }

    func testUserAndHost() {
        XCTAssertEqual(cmd("ssh://alice@example.com"), "ssh alice@example.com")
    }

    func testUserHostAndPort() {
        XCTAssertEqual(cmd("ssh://alice@example.com:2222"), "ssh -p 2222 alice@example.com")
    }

    func testPathIsIgnored() {
        XCTAssertEqual(cmd("ssh://example.com/some/remote/path"), "ssh example.com")
    }

    func testHostWithHyphenAndDots() {
        XCTAssertEqual(cmd("ssh://user@my-host.internal.example.com"), "ssh user@my-host.internal.example.com")
    }

    func testNonSSHSchemeRejected() {
        XCTAssertNil(cmd("http://example.com"))
        XCTAssertNil(cmd("sftp://example.com"))
        XCTAssertNil(cmd("telnet://example.com"))
    }

    func testEmptyHostRejected() {
        XCTAssertNil(cmd("ssh://"))
        XCTAssertNil(cmd("ssh:///path"))
    }

    func testPortOutOfRangeRejected() {
        XCTAssertNil(cmd("ssh://example.com:0"))
        XCTAssertNil(cmd("ssh://example.com:70000"))
    }

    // Injection battery: metacharacters decode (percent) or parse into host/user
    // and must all be rejected by the charset guard.
    func testInjectionAttemptsRejected() {
        XCTAssertNil(cmd("ssh://a%20b"))          // space  -> "a b"
        XCTAssertNil(cmd("ssh://a%3Bb"))          // ;      -> "a;b"
        XCTAssertNil(cmd("ssh://a%26%26b"))       // &&     -> "a&&b"
        XCTAssertNil(cmd("ssh://a%7Cb"))          // |      -> "a|b"
        XCTAssertNil(cmd("ssh://host%0Arm"))      // newline
        XCTAssertNil(cmd("ssh://%24%28whoami%29"))// $(whoami)
        XCTAssertNil(cmd("ssh://%60id%60"))       // `id`
        XCTAssertNil(cmd("ssh://user%20x@host"))  // space in user
    }

    // ssh://-Ex@host became `ssh -Ex@host`: an option, not a target
    // (pre-release sweep, 2026-11-14).
    func testUserOrHostThatLooksLikeAnOptionIsRefused() {
        XCTAssertNil(cmd("ssh://-Ex@host"))
        XCTAssertNil(cmd("ssh://-oVerbose"))
        XCTAssertEqual(cmd("ssh://me@my-host"), "ssh me@my-host")
    }
}
