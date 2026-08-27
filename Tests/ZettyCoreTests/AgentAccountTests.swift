import XCTest
@testable import ZettyCore

final class AgentAccountTests: XCTestCase {

    private let home = "/Users/tester"

    private func account(_ name: String, dir: String? = nil) -> AgentAccount {
        switch AgentAccountSupport.make(name: name, directory: dir, agentID: "claude",
                                        colorID: nil, existing: [], home: home) {
        case .success(let a): return a
        case .failure(let e): fatalError("unexpected \(e)")
        }
    }

    // MARK: Slug and paths

    /// The `@default` sentinel is safe precisely because `slug` cannot emit `@`.
    func testSlugNeverEmitsTheSentinelPrefix() {
        XCTAssertEqual(AgentAccountSupport.slug("Work Account"), "work-account")
        XCTAssertEqual(AgentAccountSupport.slug("@default"), "default")
        XCTAssertFalse(AgentAccountSupport.slug("@@@ weird @@@").contains("@"))
    }

    func testDefaultDirectoryLivesUnderZettyAccounts() {
        XCTAssertEqual(AgentAccountSupport.defaultDirectory(home: home, slug: "work"),
                       "/Users/tester/.zetty/accounts/work")
    }

    func testDirectoryIsStoredTildeAbbreviated() {
        XCTAssertEqual(account("Work").directory, "~/.zetty/accounts/work")
    }

    // MARK: Validation

    func testRejectsBlankAndUnsluggableNames() {
        for name in ["", "   ", "@@@"] {
            XCTAssertEqual(AgentAccountSupport.make(name: name, directory: nil, agentID: "claude",
                                                    colorID: nil, existing: [], home: home),
                           .failure(.blankName), "expected blankName for \(name.debugDescription)")
        }
    }

    func testRejectsDuplicateNameCaseInsensitively() {
        let existing = [account("Work")]
        XCTAssertEqual(AgentAccountSupport.make(name: "wOrK", directory: nil, agentID: "claude",
                                                colorID: nil, existing: existing, home: home),
                       .failure(.duplicateName))
    }

    func testRejectsDuplicateDirectory() {
        let existing = [account("Work")]
        XCTAssertEqual(AgentAccountSupport.make(name: "Other",
                                                directory: "~/.zetty/accounts/work",
                                                agentID: "claude", colorID: nil,
                                                existing: existing, home: home),
                       .failure(.duplicateDirectory))
    }

    /// `~/.claude` IS the default account. An account pointing there would get a
    /// DIFFERENT Keychain item than the real default login while looking identical.
    func testRejectsDirectoryEqualToTheAgentsOwnHome() {
        XCTAssertEqual(AgentAccountSupport.make(name: "Sneaky", directory: "~/.claude",
                                                agentID: "claude", colorID: nil,
                                                existing: [], home: home),
                       .failure(.directoryIsAgentHome))
    }

    func testRejectsHomeOrAnAncestorOfIt() {
        for dir in ["~", "/Users", "/"] {
            XCTAssertEqual(AgentAccountSupport.make(name: "Bad", directory: dir, agentID: "claude",
                                                    colorID: nil, existing: [], home: home),
                           .failure(.directoryIsHomeOrAncestor), "expected refusal for \(dir)")
        }
    }

    func testRejectsRelativeDirectory() {
        XCTAssertEqual(AgentAccountSupport.make(name: "Bad", directory: "accounts/work",
                                                agentID: "claude", colorID: nil,
                                                existing: [], home: home),
                       .failure(.relativeDirectory))
    }

    /// The path becomes `env = CLAUDE_CONFIG_DIR=<dir>` on ONE line, and
    /// libghostty frees the WHOLE config on any diagnostic — taking the
    /// per-surface `command` with it and stranding preserved sessions. Until a
    /// space is measured to survive ghostty's parser, refuse it at the source.
    func testRejectsDirectoryWithUnsafeCharacters() {
        for dir in ["/Users/tester/My Accounts", "/Users/tester/a\nb", "/Users/tester/a#b"] {
            XCTAssertEqual(AgentAccountSupport.make(name: "Bad", directory: dir, agentID: "claude",
                                                    colorID: nil, existing: [], home: home),
                           .failure(.directoryHasUnsafeCharacters), "expected refusal for \(dir)")
        }
    }

    func testAcceptsAnOrdinaryCustomDirectory() {
        XCTAssertEqual(account("Side", dir: "/Users/tester/.config/claude-side").directory,
                       "~/.config/claude-side")
    }

    // MARK: Coding

    func testDecodesWithoutOptionalFields() throws {
        let json = #"{"id":"work","name":"Work","directory":"~/.zetty/accounts/work"}"#
        let decoded = try JSONDecoder().decode(AgentAccount.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, "work")
        XCTAssertEqual(decoded.agentID, "claude")   // defaulted, not required
        XCTAssertNil(decoded.colorID)
        XCTAssertNil(decoded.lastKnownEmail)
    }

    func testFileDecodesFromEmptyObject() throws {
        let decoded = try JSONDecoder().decode(AgentAccountsFile.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.accounts.isEmpty)
    }

    func testFileRoundTrips() throws {
        var file = AgentAccountsFile()
        file.upsert(account("Work"))
        file.upsert(account("Personal"))
        let data = try JSONEncoder().encode(file)
        let back = try JSONDecoder().decode(AgentAccountsFile.self, from: data)
        XCTAssertEqual(back, file)
        XCTAssertEqual(back.account(named: "wORK")?.id, "work")
        XCTAssertNil(back.account(named: "nope"))
    }

    func testUpsertReplacesInPlaceAndRemoveDrops() {
        var file = AgentAccountsFile()
        file.upsert(account("Work"))
        var edited = file.account(id: "work")!
        edited.name = "Work Renamed"
        file.upsert(edited)
        XCTAssertEqual(file.accounts.count, 1)
        XCTAssertEqual(file.accounts[0].name, "Work Renamed")
        file.remove(id: "work")
        XCTAssertTrue(file.accounts.isEmpty)
    }
}

// MARK: - Adding the same account twice

extension AgentAccountTests {

    /// Two accounts sharing one config directory would fight over the same
    /// `.claude.json` (it is lock-protected and watched across processes), so
    /// the name — which derives the directory — has to be unique.
    func testCannotAddTheSameAccountTwice() {
        let existing = [account("Warda")]
        for attempt in ["Warda", "warda", "  WARDA  "] {
            XCTAssertEqual(
                AgentAccountSupport.make(name: attempt, directory: nil, agentID: "claude",
                                         colorID: nil, existing: existing, home: home),
                .failure(.duplicateName),
                "\(attempt.debugDescription) should be refused as a duplicate")
        }
    }

    /// A differently-named account is a genuinely different login with its own
    /// directory, so it is allowed — this is not a duplicate.
    func testASimilarNameIsStillANewAccount() {
        let existing = [account("Warda")]
        switch AgentAccountSupport.make(name: "Warda Personal", directory: nil, agentID: "claude",
                                        colorID: nil, existing: existing, home: home) {
        case .success(let made):
            XCTAssertEqual(made.id, "warda-personal")
            XCTAssertEqual(made.directory, "~/.zetty/accounts/warda-personal")
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    /// Removing an account deliberately leaves its directory (and login) on
    /// disk, so re-adding the same name must be allowed and must land back on
    /// the same directory — that is what "add it back" means.
    func testReAddingAfterRemovalReusesTheSameDirectory() {
        let original = account("Warda")
        var file = AgentAccountsFile()
        file.upsert(original)
        file.remove(id: original.id)

        switch AgentAccountSupport.make(name: "Warda", directory: nil, agentID: "claude",
                                        colorID: nil, existing: file.accounts, home: home) {
        case .success(let readded):
            XCTAssertEqual(readded.directory, original.directory)
            XCTAssertEqual(readded.id, original.id)
        case .failure(let error):
            XCTFail("re-adding a removed account should work, got \(error)")
        }
    }

    /// Even if a duplicate ever reached the store, it cannot show up twice.
    func testUpsertCannotProduceTwoRowsForOneAccount() {
        var file = AgentAccountsFile()
        file.upsert(account("Warda"))
        file.upsert(account("Warda"))
        XCTAssertEqual(file.accounts.count, 1)
    }
}
