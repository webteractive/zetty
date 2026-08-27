import XCTest
@testable import ZettyCore

final class AccountSeedTests: XCTestCase {

    /// The denylist is deliberately a SEPARATE list from `shareable`, so that
    /// adding a shareable item later cannot leak credentials by omission.
    /// Every account-capable agent, not just Claude: a new agent's lists have
    /// to satisfy the same invariants or it can leak credentials.
    private var accountAgents: [String] { SpawnableAgent.accountCapable.map(\.id) }

    func testShareableAndIdentityAreDisjointForEveryAgent() {
        for agent in accountAgents {
            let identity = AccountSeed.identity(forAgent: agent)
            for item in AccountSeed.shareable(forAgent: agent) {
                XCTAssertFalse(identity.contains(item.id),
                               "\(agent): \(item.id) is offered for sharing AND listed as identity")
            }
        }
    }

    func testEveryAccountCapableAgentHasSeedLists() {
        for agent in accountAgents {
            XCTAssertFalse(AccountSeed.shareable(forAgent: agent).isEmpty, agent)
            XCTAssertFalse(AccountSeed.identity(forAgent: agent).isEmpty, agent)
        }
    }

    /// An agent Zetty can't host accounts for shares nothing at all.
    func testUnknownAgentSharesNothing() {
        XCTAssertTrue(AccountSeed.shareable(forAgent: "hermes").isEmpty)
        XCTAssertFalse(AccountSeed.isShareable("skills", forAgent: "hermes"))
    }

    func testIsShareableRefusesEveryIdentityPath() {
        for agent in accountAgents {
            for path in AccountSeed.identity(forAgent: agent) {
                XCTAssertFalse(AccountSeed.isShareable(path, forAgent: agent),
                               "\(agent): \(path) must never be shareable")
            }
        }
    }

    func testCredentialBearingPathsAreOnTheDenylist() {
        for path in [".claude.json", ".credentials.json", "projects", "history.jsonl", "sessions"] {
            XCTAssertTrue(AccountSeed.identity(forAgent: "claude").contains(path),
                          "claude: \(path) must be denied")
        }
        // Codex keeps its credentials in a plain file inside the config dir, so
        // that file is the one thing that must never be shared.
        for path in ["auth.json", "sessions", "history.jsonl", "installation_id"] {
            XCTAssertTrue(AccountSeed.identity(forAgent: "codex").contains(path),
                          "codex: \(path) must be denied")
        }
    }

    func testIsShareableRefusesTraversalAndAbsolutePaths() {
        for path in ["../.claude.json", "/etc/passwd", "skills/../.credentials.json", ""] {
            XCTAssertFalse(AccountSeed.isShareable(path, forAgent: "claude"))
        }
    }

    /// settings.json is COPIED, never symlinked: Claude rewrites it (plugin
    /// enable/disable, onboarding flags), so a shared link is last-writer-wins
    /// between two live processes — and each account needs its own file for
    /// Zetty's agent hooks to live in.
    func testSettingsIsCopiedAndRequired() {
        let settings = AccountSeed.shareable(forAgent: "claude").first { $0.id == "settings.json" }
        XCTAssertEqual(settings?.treatment, .copy)
        XCTAssertTrue(settings?.isRequired == true)
        // Codex's equivalent: the hook Zetty installs lives in config.toml.
        let config = AccountSeed.shareable(forAgent: "codex").first { $0.id == "config.toml" }
        XCTAssertEqual(config?.treatment, .copy)
        XCTAssertTrue(config?.isRequired == true)
    }

    /// plugins/ is a mutable state store (marketplace JSON, catalog cache, git
    /// clones) — two processes writing through one link corrupts it.
    /// A mutable state store for both agents — two processes writing through
    /// one link corrupts it.
    func testPluginsIsNotOfferedForEitherAgent() {
        for agent in ["claude", "codex"] {
            XCTAssertNil(AccountSeed.shareable(forAgent: agent).first { $0.id == "plugins" }, agent)
            XCTAssertFalse(AccountSeed.isShareable("plugins", forAgent: agent), agent)
        }
    }

    func testReadOnlyContentIsSymlinked() {
        for id in ["skills", "commands", "agents", "CLAUDE.md"] {
            let item = AccountSeed.shareable(forAgent: "claude").first { $0.id == id }
            XCTAssertEqual(item?.treatment, .symlink, "\(id) should be symlinked")
        }
        for id in ["AGENTS.md", "skills", "rules"] {
            let item = AccountSeed.shareable(forAgent: "codex").first { $0.id == id }
            XCTAssertEqual(item?.treatment, .symlink, "codex \(id) should be symlinked")
        }
    }

    func testPlanAlwaysIncludesRequiredItemsAndOnlySelectedOptionalOnes() {
        let plan = AccountSeed.plan(selecting: ["skills"], forAgent: "claude")
        XCTAssertEqual(Set(plan.map(\.id)), ["settings.json", "skills"])
    }

    func testPlanIgnoresUnknownAndDeniedSelections() {
        let plan = AccountSeed.plan(selecting: [".credentials.json", "plugins", "nope"],
                                    forAgent: "claude")
        XCTAssertEqual(plan.map(\.id), ["settings.json"])
        // Codex's auth.json is the login itself and can never be smuggled in.
        XCTAssertEqual(AccountSeed.plan(selecting: ["auth.json"], forAgent: "codex").map(\.id),
                       ["config.toml"])
    }
}

// MARK: - Preference seeding

/// `claude auth login` authenticates without marking onboarding complete, and a
/// fresh config dir has no onboarding state — so interactive `claude` runs its
/// first-run flow, which OPENS WITH a login prompt despite valid credentials.
/// Carrying a few preference keys across is what stops a signed-in account
/// looking signed-out.
extension AccountSeedTests {

    func testSeedsOnboardingCompletionWhenTheAccountLacksIt() {
        let keys = AccountSeed.preferenceKeysToSeed(
            available: ["hasCompletedOnboarding", "theme", "oauthAccount"],
            existing: [])
        XCTAssertTrue(keys.contains("hasCompletedOnboarding"))
        XCTAssertTrue(keys.contains("theme"))
    }

    /// Non-destructive: a preference the account already set is never replaced.
    func testNeverOverwritesAPreferenceTheAccountAlreadyHas() {
        let keys = AccountSeed.preferenceKeysToSeed(
            available: ["hasCompletedOnboarding", "theme"],
            existing: ["theme"])
        XCTAssertEqual(keys, ["hasCompletedOnboarding"])
    }

    /// Idempotent, which is what makes it safe to re-run on every sign-in —
    /// that is how an account created before this existed repairs itself.
    func testIsANoOpOnceEverythingIsSeeded() {
        XCTAssertTrue(AccountSeed.preferenceKeysToSeed(
            available: Set(AccountSeed.preferenceKeys),
            existing: Set(AccountSeed.preferenceKeys)).isEmpty)
    }

    func testSkipsKeysTheSourceDoesNotHave() {
        XCTAssertEqual(AccountSeed.preferenceKeysToSeed(
            available: ["theme"], existing: []), ["theme"])
    }

    /// The allowlist is the whole safety argument: identity and history can't
    /// ride along, because nothing not named in it is copied at all.
    func testIdentityAndHistoryAreUnreachable() {
        for key in AccountSeed.neverCopiedKeys {
            XCTAssertFalse(AccountSeed.preferenceKeys.contains(key),
                           "\(key) must never be copied between accounts")
        }
        let keys = AccountSeed.preferenceKeysToSeed(
            available: AccountSeed.neverCopiedKeys.union(["theme"]), existing: [])
        XCTAssertEqual(keys, ["theme"])
    }
}
