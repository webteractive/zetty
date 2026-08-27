import XCTest
@testable import ZettyCore

final class AccountCLITests: XCTestCase {

    private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(ControlRequest.self, from: data)
    }

    /// A verb missing from `recognizes` silently launches the GUI instead of
    /// running — the failure mode is a second app window, not an error.
    func testAccountsIsARecognizedVerb() {
        XCTAssertTrue(ControlCLI.recognizes(["accounts"]))
    }

    func testAccountsRequestRoundTrips() throws {
        XCTAssertEqual(try roundTrip(.accounts(probe: true)), .accounts(probe: true))
        XCTAssertEqual(try roundTrip(.accounts(probe: false)), .accounts(probe: false))
    }

    func testNewTabAndSplitCarryTheAccount() throws {
        XCTAssertEqual(try roundTrip(.newTab(project: "p", focus: false, account: "work")),
                       .newTab(project: "p", focus: false, account: "work"))
        XCTAssertEqual(try roundTrip(.split(target: .focused, vertical: true, focus: false,
                                            account: "personal")),
                       .split(target: .focused, vertical: true, focus: false, account: "personal"))
    }

    /// An older app's payload has no `account` key; a newer CLI must not throw.
    func testNewTabDecodesWithoutAnAccountKey() throws {
        let json = #"{"command":"new-tab","focus":false}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .newTab(project: nil, focus: false, account: nil))
    }

    func testAccountsResponseRoundTrips() throws {
        let snapshot = AccountsSnapshot(
            accounts: [.init(id: "work", name: "Work", directory: "~/.zetty/accounts/work",
                             agent: "claude", email: "a@b.c", orgName: "Acme", loggedIn: true)],
            defaultDirectory: "~/.claude")
        let data = try JSONEncoder().encode(ControlResponse.accounts(snapshot))
        XCTAssertEqual(try JSONDecoder().decode(ControlResponse.self, from: data),
                       .accounts(snapshot))
    }

    /// An older standalone `zetty` must not throw on a newer app's payload.
    func testAccountsSnapshotDecodesWithoutOptionalFields() throws {
        let json = #"{"accounts":[{"id":"work","name":"Work"}]}"#
        let decoded = try JSONDecoder().decode(AccountsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.accounts.first?.name, "Work")
        XCTAssertNil(decoded.accounts.first?.email)
        XCTAssertNil(decoded.defaultDirectory)
    }

    func testStatusPaneDecodesWithoutAnAccount() throws {
        let json = #"{"id":"abc","isFocused":false,"live":true}"#
        let pane = try JSONDecoder().decode(StatusSnapshot.Pane.self, from: Data(json.utf8))
        XCTAssertNil(pane.account)
    }

    // MARK: Rendering

    func testAccountLinesAlwaysListTheDefault() {
        let lines = ControlCLI.accountLines(AccountsSnapshot(accounts: [], defaultDirectory: "~/.claude"))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("default"))
        XCTAssertTrue(lines[0].contains("~/.claude"))
    }

    func testAccountLinesNameTheAgent() {
        let snapshot = AccountsSnapshot(
            accounts: [.init(id: "work", name: "Work", directory: "~/d", agent: "claude")])
        XCTAssertTrue(ControlCLI.accountLines(snapshot)[0].contains("claude"))
    }

    func testAccountLinesShowIdentityAndDirectory() {
        let snapshot = AccountsSnapshot(
            accounts: [.init(id: "work", name: "Work", directory: "~/.zetty/accounts/work",
                             agent: "claude", email: "a@b.c", orgName: "Acme", loggedIn: true)],
            defaultDirectory: "~/.claude")
        let line = ControlCLI.accountLines(snapshot)[0]
        XCTAssertTrue(line.contains("Work"))
        XCTAssertTrue(line.contains("a@b.c · Acme"))
        XCTAssertTrue(line.contains("~/.zetty/accounts/work"))
    }

    func testAccountLinesSayWhenIdentityWasNeverProbed() {
        let snapshot = AccountsSnapshot(
            accounts: [.init(id: "work", name: "Work", directory: "~/d")])
        XCTAssertTrue(ControlCLI.accountLines(snapshot)[0].contains("--probe"))
    }

    /// The marker is for spotting the exception; a default-login pane is
    /// unmarked so ordinary output stays quiet.
    func testStatusLinesMarkOnlyNonDefaultPanes() {
        func snapshot(account: String?) -> StatusSnapshot {
            StatusSnapshot(projects: [
                .init(name: "p", isActive: true, hibernated: false, tabs: [
                    .init(title: "t", isActive: true, panes: [
                        .init(id: "abc12345", title: nil, cwd: nil, tool: nil, agentStatus: nil,
                              isFocused: true, live: true, account: account),
                    ]),
                ]),
            ])
        }
        XCTAssertTrue(ControlCLI.statusLines(snapshot(account: "Work"))
            .contains { $0.contains("·Work·") })
        XCTAssertFalse(ControlCLI.statusLines(snapshot(account: nil))
            .contains { $0.contains("·") })
    }
}
