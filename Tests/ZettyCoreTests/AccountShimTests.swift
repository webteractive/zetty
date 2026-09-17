import Testing
@testable import ZettyCore

private let cliPath = "/Users/tester/.local/bin/zetty"

private func account(_ name: String) -> AgentAccount {
    AgentAccount(id: AgentAccountSupport.slug(name), name: name,
                 directory: "~/.zetty/accounts/\(AgentAccountSupport.slug(name))")
}

@Test func shimNameIsPrefixedSlugOfTheAccountName() {
    #expect(AccountShim.name(for: account("Personal")) == "z-personal")
    #expect(AccountShim.name(for: account("Work Account")) == "z-work-account")
}

@Test func shimScriptCarriesMarkerAndExecsTheCLI() {
    let script = AccountShim.scriptContents(cliPath: cliPath, accountName: "Personal")
    #expect(script.hasPrefix("#!/bin/sh\n"))
    #expect(script.contains(AccountShim.marker))
    #expect(script.contains("exec '/Users/tester/.local/bin/zetty' run 'Personal' \"$@\""))
}

// Names are single-quoted, so a name with a space or an apostrophe cannot
// break out of the generated script.
@Test func shimScriptQuotesHostileAccountNames() {
    let script = AccountShim.scriptContents(cliPath: cliPath, accountName: "Glen's Work")
    #expect(script.contains(#"run 'Glen'\''s Work'"#))
}

@Test func reconcileWritesMissingShims() {
    let (write, remove) = AccountShim.reconcile(
        accounts: [account("Personal"), account("Work")],
        cliPath: cliPath, existing: [])
    #expect(write.map(\.name).sorted() == ["z-personal", "z-work"])
    #expect(write.allSatisfy { $0.contents.contains(AccountShim.marker) })
    #expect(remove.isEmpty)
}

@Test func reconcileRemovesShimsNoAccountClaims() {
    let (write, remove) = AccountShim.reconcile(
        accounts: [account("Personal")],
        cliPath: cliPath, existing: ["z-personal", "z-deleted"])
    #expect(remove == ["z-deleted"])
    // Still rewritten, so a stale CLI path or an edited file self-heals.
    #expect(write.map(\.name) == ["z-personal"])
}

@Test func reconcileWithNoAccountsRemovesEverything() {
    let (write, remove) = AccountShim.reconcile(
        accounts: [], cliPath: cliPath, existing: ["z-personal", "z-work"])
    #expect(write.isEmpty)
    #expect(remove.sorted() == ["z-personal", "z-work"])
}
