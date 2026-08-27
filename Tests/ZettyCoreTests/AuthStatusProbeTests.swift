import XCTest
@testable import ZettyCore

final class AuthStatusProbeTests: XCTestCase {

    func testParsesLoggedInIdentity() {
        let output = """
        {"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
         "email": "glen@example.com", "orgName": "More.dev", "subscriptionType": "team"}
        """
        let status = AuthStatusProbe.parse(output, format: .claudeJSON)
        XCTAssertEqual(status?.loggedIn, true)
        XCTAssertEqual(status?.email, "glen@example.com")
        XCTAssertEqual(status?.orgName, "More.dev")
        XCTAssertEqual(status?.subscriptionType, "team")
    }

    func testParsesLoggedOut() {
        let status = AuthStatusProbe.parse(#"{"loggedIn": false}"#, format: .claudeJSON)
        XCTAssertEqual(status?.loggedIn, false)
        XCTAssertNil(status?.email)
    }

    /// The command may print a banner or a warning around its JSON.
    func testIgnoresSurroundingNoise() {
        let output = "Checking…\n{\"loggedIn\": true, \"email\": \"a@b.c\"}\nDone.\n"
        XCTAssertEqual(AuthStatusProbe.parse(output, format: .claudeJSON)?.email, "a@b.c")
    }

    func testReturnsNilOnGarbageOrEmptyOutput() {
        for output in ["", "not json", "{", "}{"] {
            XCTAssertNil(AuthStatusProbe.parse(output, format: .claudeJSON), "expected nil for \(output.debugDescription)")
        }
    }

    func testEmptyStringFieldsBecomeNil() {
        XCTAssertNil(AuthStatusProbe.parse(#"{"loggedIn":true,"email":""}"#, format: .claudeJSON)?.email)
    }

    /// The arguments and the output shape now live on the agent, so Codex's
    /// prose status can be read alongside Claude's JSON.
    func testEachAgentDeclaresHowToProbeIt() {
        let claude = SpawnableAgent.byID("claude")
        XCTAssertEqual(claude?.statusArguments, ["auth", "status", "--json"])
        XCTAssertEqual(claude?.statusFormat, .claudeJSON)

        let codex = SpawnableAgent.byID("codex")
        XCTAssertEqual(codex?.statusArguments, ["login", "status"])
        XCTAssertEqual(codex?.statusFormat, .plainText)
        XCTAssertEqual(codex?.configDirEnvVar, "CODEX_HOME")
    }

    // MARK: Plain-text status (Codex)

    /// "Not logged in" CONTAINS "logged in", so the negative must win.
    func testPlainTextReadsNotLoggedInBeforeLoggedIn() {
        XCTAssertEqual(AuthStatusProbe.parse("Not logged in", format: .plainText)?.loggedIn, false)
        XCTAssertEqual(
            AuthStatusProbe.parse("Logged in using ChatGPT", format: .plainText)?.loggedIn, true)
    }

    /// Prose carries no identity — the account is known to be signed in, but
    /// not as whom.
    func testPlainTextYieldsNoIdentity() {
        let status = AuthStatusProbe.parse("Logged in using ChatGPT", format: .plainText)
        XCTAssertNil(status?.email)
        XCTAssertNil(status?.orgName)
    }

    func testPlainTextReturnsNilWhenItSaysNeither() {
        XCTAssertNil(AuthStatusProbe.parse("error: something broke", format: .plainText))
    }
}
