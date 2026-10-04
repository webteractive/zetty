import Foundation
import Testing
@testable import ZettyCore

private let surface = UUID(uuidString: "E7AE73DA-B1D9-4649-A122-02134E893AE8")!

/// A snapshot exactly as the mod wrote it for a live pane.
private let live = #"""
{"v":1,"agent":"claude","surface":"E7AE73DA-B1D9-4649-A122-02134E893AE8","session":"5508e3ae-4e6c-41f8-88ee-c96d558026b1","cwd":"/Users/me/zetty","config":"/Users/me/.zetty/accounts/work","model":"claude-opus-5-5","turn":{"state":"idle","reason":"answer","durationMs":4200},"context":{"tokens":150268,"window":1000000,"percent":15},"costUSD":2.0241553999999997,"rateLimits":[{"kind":"five_hour","percentUsed":14,"resetsAt":"2026-10-04T06:40:00.000Z"},{"kind":"seven_day","percentUsed":12.5}],"updatedAt":1791082501384}
"""#

private func parse(_ json: String) -> AgentUsage? {
    AgentUsage.parse(data: Data(json.utf8))
}

@Test func agentUsageParsesALiveSnapshot() throws {
    let usage = try #require(parse(live))
    #expect(usage.surface == surface)
    #expect(usage.session == "5508e3ae-4e6c-41f8-88ee-c96d558026b1")
    #expect(usage.cwd == "/Users/me/zetty")
    #expect(usage.model == "claude-opus-5-5")
    #expect(usage.configDirectory == "/Users/me/.zetty/accounts/work")
    #expect(usage.turnState == .idle)
    #expect(usage.turnReason == "answer")
    #expect(usage.contextTokens == 150_268)
    #expect(usage.contextWindow == 1_000_000)
    #expect(usage.contextPercent == 15)
    #expect(usage.costUSD == 2.0241553999999997)
    #expect(usage.rateLimits.map(\.kind) == ["five_hour", "seven_day"])
    #expect(usage.rateLimits[0].resetsAt == Date(timeIntervalSince1970: 1_791_096_000))
    #expect(usage.rateLimits[1].resetsAt == nil)
    #expect(usage.updatedAt == 1_791_082_501.384)
}

@Test func agentUsageKeepsAnEmptyConfigApartFromAMissingOne() {
    // "" is the default login; a missing field says nothing at all.
    let unset = parse(#"{"v":1,"agent":"claude","surface":"\#(surface.uuidString)","config":""}"#)
    let silent = parse(#"{"v":1,"agent":"claude","surface":"\#(surface.uuidString)"}"#)
    #expect(unset?.configDirectory == "")
    #expect(silent?.configDirectory == nil)
}

@Test func agentUsageReadsASnapshotWithNoFillYet() throws {
    // Before the first response the mod knows the window but not its fill.
    let usage = try #require(parse(
        #"{"v":1,"agent":"claude","surface":"\#(surface.uuidString)","turn":{"state":"running"},"context":{"window":200000},"rateLimits":[]}"#))
    #expect(usage.turnState == .running)
    #expect(usage.contextPercent == nil)
    #expect(usage.contextWindow == 200_000)
}

@Test func agentUsageRejectsWhatItCannotTrust() {
    #expect(parse("") == nil)
    // Caught mid-write: the mod's write is not atomic.
    #expect(parse(String(live.prefix(120))) == nil)
    #expect(parse(#"{"v":2,"agent":"claude","surface":"\#(surface.uuidString)"}"#) == nil)
    #expect(parse(#"{"v":1,"agent":"codex","surface":"\#(surface.uuidString)"}"#) == nil)
    #expect(parse(#"{"v":1,"agent":"claude","surface":"../../etc/passwd"}"#) == nil)
}

@Test func agentUsageDropsASessionIDAShellCouldInterpret() {
    let usage = parse(#"{"v":1,"agent":"claude","surface":"\#(surface.uuidString)","session":"a; rm -rf ~"}"#)
    #expect(usage != nil)
    #expect(usage?.session == nil)
}

@Test func agentUsageFileNamesRoundTrip() {
    #expect(AgentUsage.fileName(for: surface) == "E7AE73DA-B1D9-4649-A122-02134E893AE8.json")
    #expect(AgentUsage.surface(fromFileName: AgentUsage.fileName(for: surface)) == surface)
    #expect(AgentUsage.surface(fromFileName: "notes.json") == nil)
    #expect(AgentUsage.surface(fromFileName: "\(surface.uuidString).cwd") == nil)
}

@Test func agentUsageIsHiddenOnceTheSessionEndsOrAnotherProcessOwnsThePane() {
    var usage = AgentUsage(surface: surface, contextPercent: 40)
    #expect(usage.isShown(foreground: "claude"))
    // No probe (preserve-sessions off): the snapshot's own word stands.
    #expect(usage.isShown(foreground: nil))
    // A Claude killed without a session.end leaves its file behind.
    #expect(!usage.isShown(foreground: "zsh"))
    #expect(!usage.isShown(foreground: ""))
    usage.turnState = .ended
    #expect(!usage.isShown(foreground: "claude"))
}

@Test func agentUsageStoreReportsOnlyVisibleChanges() {
    var store = AgentUsageStore()
    var usage = AgentUsage(surface: surface, turnState: .running, contextTokens: 150_268,
                           contextWindow: 1_000_000, contextPercent: 15, costUSD: 2.024,
                           rateLimits: [.init(kind: "five_hour", percentUsed: 14.2)],
                           updatedAt: 100)
    let first = store.apply(usage)
    #expect(first)

    // Tokens, cost and a limit ticking inside what is displayed, plus a new
    // timestamp: nothing a view shows has moved.
    usage.updatedAt = 101
    usage.contextTokens = 150_900
    usage.costUSD = 2.026
    usage.rateLimits = [.init(kind: "five_hour", percentUsed: 14.4)]
    let ticked = store.apply(usage)
    #expect(!ticked)
    #expect(store.usage(for: surface)?.contextTokens == 150_900)

    usage.contextPercent = 16
    let filled = store.apply(usage)
    #expect(filled)
    usage.turnState = .idle
    let stopped = store.apply(usage)
    #expect(stopped)
}

@Test func agentUsageStoreForgetsAPane() {
    var store = AgentUsageStore()
    store.apply(AgentUsage(surface: surface))
    #expect(store.surfaces == [surface])
    let removed = store.remove(surface)
    let again = store.remove(surface)
    #expect(removed)
    #expect(!again)
    #expect(store.usage(for: surface) == nil)
}

// MARK: - ModInstall

@Test func modInstallCopiesWhenTheVersionDiffers() {
    let v1 = Data(#"{"name":"zetty-bridge","version":"0.1.0"}"#.utf8)
    let v2 = Data(#"{"name":"zetty-bridge","version":"0.2.0"}"#.utf8)
    #expect(ModInstall.needsInstall(bundled: v2, installed: nil))
    #expect(ModInstall.needsInstall(bundled: v2, installed: v1))
    // A downgrade counts: the copy must match the app reading its snapshots.
    #expect(ModInstall.needsInstall(bundled: v1, installed: v2))
    #expect(ModInstall.needsInstall(bundled: v1, installed: Data("garbage".utf8)))
    #expect(!ModInstall.needsInstall(bundled: v1, installed: v1))
    // Nothing to install from.
    #expect(!ModInstall.needsInstall(bundled: nil, installed: v1))
}

@Test func modInstallPluginDirsIsIdempotentAndKeepsTheUsersOwn() {
    let mod = "/Users/me/.zetty/mods/zetty-bridge"
    #expect(ModInstall.installedPath(home: "/Users/me") == mod)
    #expect(ModInstall.pluginDirs(existing: nil, modPath: mod, enabled: true) == mod)
    #expect(ModInstall.pluginDirs(existing: mod, modPath: mod, enabled: true) == mod)
    #expect(ModInstall.pluginDirs(existing: "/my/mod", modPath: mod, enabled: true) == "/my/mod:\(mod)")
    #expect(ModInstall.pluginDirs(existing: "\(mod):/my/mod", modPath: mod, enabled: true) == "/my/mod:\(mod)")
    // Off takes ours out and leaves theirs; nothing left means unset.
    #expect(ModInstall.pluginDirs(existing: "/my/mod:\(mod)", modPath: mod, enabled: false) == "/my/mod")
    #expect(ModInstall.pluginDirs(existing: mod, modPath: mod, enabled: false) == nil)
    #expect(ModInstall.pluginDirs(existing: "", modPath: mod, enabled: false) == nil)
}

// MARK: - Config

@Test func claudeModKeyIsZettysOwnAndDefaultsOn() {
    #expect(AppConfig.parse("").claudeMod)
    let off = AppConfig.parse("zetty-claude-mod = false")
    #expect(!off.claudeMod)
    // Never forwarded to ghostty, whose all-or-nothing validation would drop
    // every custom setting with it.
    #expect(!off.ghostty.contains { $0.key == "zetty-claude-mod" })
    #expect(!off.unsupportedKeys.contains("zetty-claude-mod"))
    #expect(AppConfig.parse(off.rendered()).claudeMod == false)
}

@Test func claudeToolsKeyIsZettysOwnAndDefaultsOn() {
    #expect(AppConfig.parse("").claudeTools)
    let off = AppConfig.parse("zetty-claude-tools = false")
    #expect(!off.claudeTools)
    #expect(off.claudeMod)   // the tools switch does not take the mod with it
    #expect(!off.ghostty.contains { $0.key == "zetty-claude-tools" })
    #expect(AppConfig.parse(off.rendered()).claudeTools == false)
}

// MARK: - Attention and failed turns

@Test func agentUsageReadsTheAttentionMessageAsOneBoundedLine() throws {
    let usage = try #require(parse(
        #"{"v":1,"agent":"claude","surface":"\#(surface.uuidString)","attention":{"message":"  Claude needs your permission\nto use Bash  ","type":"permission_prompt"}}"#))
    #expect(usage.attention == .init(message: "Claude needs your permission to use Bash",
                                     type: "permission_prompt"))
    let long = String(repeating: "x", count: 500)
    let clipped = parse(#"{"v":1,"agent":"claude","surface":"\#(surface.uuidString)","attention":{"message":"\#(long)"}}"#)
    #expect(clipped?.attention?.message.count == 200)
    // An empty message is no message.
    #expect(parse(#"{"v":1,"agent":"claude","surface":"\#(surface.uuidString)","attention":{"message":"  "}}"#)?.attention == nil)
}

@Test func agentUsageCallsAnErrorOrRefusalAFailedTurn() {
    func usage(_ state: AgentUsage.TurnState, _ reason: String?) -> AgentUsage {
        AgentUsage(surface: surface, turnState: state, turnReason: reason)
    }
    #expect(usage(.idle, "error").turnFailed)
    #expect(usage(.idle, "refusal").turnFailed)
    #expect(usage(.idle, "error").failureDescription == "API error")
    #expect(usage(.idle, "refusal").failureDescription == "refused")
    // The user's own interrupt, a normal answer, and a turn still running.
    #expect(!usage(.idle, "aborted").turnFailed)
    #expect(!usage(.idle, "answer").turnFailed)
    #expect(!usage(.running, "error").turnFailed)
    #expect(usage(.idle, "answer").failureDescription == nil)
}

@Test func displayedStatusMarksAnIdleAgentWhoseTurnFailed() {
    let failed = AgentUsage(surface: surface, turnState: .idle, turnReason: "error")
    #expect(AgentStatus.displayed(.idle, usage: failed, foreground: "claude") == .errored)
    #expect(AgentStatus.displayed(nil, usage: failed, foreground: nil) == .errored)
    // The hooks' word wins: a new turn, or a wait on the user, is more current.
    #expect(AgentStatus.displayed(.running, usage: failed, foreground: "claude") == .running)
    #expect(AgentStatus.displayed(.needsAttention, usage: failed, foreground: "claude") == .needsAttention)
    // A snapshot left by a Claude that is gone marks nothing.
    #expect(AgentStatus.displayed(.idle, usage: failed, foreground: "zsh") == .idle)
    let fine = AgentUsage(surface: surface, turnState: .idle, turnReason: "answer")
    #expect(AgentStatus.displayed(.idle, usage: fine, foreground: "claude") == .idle)
    #expect(AgentStatus.displayed(.idle, usage: nil, foreground: "claude") == .idle)
}
