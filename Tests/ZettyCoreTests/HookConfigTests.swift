import Testing
@testable import ZettyCore

private let script = "/Users/me/.quertty/hooks/quertty-hook.py"

// MARK: - Claude

private func claudeCommands(_ settings: [String: Any], event: String) -> [String] {
    guard let hooks = settings["hooks"] as? [String: Any],
          let groups = hooks[event] as? [[String: Any]] else { return [] }
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

@Test func claudeInstallAddsHooksForEachEvent() {
    let out = ClaudeHookConfig.install(into: [:], scriptPath: script)
    #expect(claudeCommands(out, event: "Notification") == ["\(script) emit claude needsAttention"])
    #expect(claudeCommands(out, event: "Stop") == ["\(script) emit claude idle"])
    #expect(ClaudeHookConfig.isInstalled(in: out, scriptPath: script))
}

@Test func claudeInstallIsIdempotentAndPreservesOthers() {
    var settings: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "/other/thing.sh"]]]]]]
    settings = ClaudeHookConfig.install(into: settings, scriptPath: script)
    settings = ClaudeHookConfig.install(into: settings, scriptPath: script)   // twice
    let stop = claudeCommands(settings, event: "Stop")
    #expect(stop.filter { $0.contains(script) }.count == 1)   // no duplicate
    #expect(stop.contains("/other/thing.sh"))                 // user's hook preserved
}

@Test func claudeUninstallRemovesOnlyOurs() {
    var settings: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "/other/thing.sh"]]]]]]
    settings = ClaudeHookConfig.install(into: settings, scriptPath: script)
    settings = ClaudeHookConfig.uninstall(from: settings, scriptPath: script)
    #expect(!ClaudeHookConfig.isInstalled(in: settings, scriptPath: script))
    #expect(claudeCommands(settings, event: "Stop") == ["/other/thing.sh"])   // user's hook intact
}

// MARK: - Codex

@Test func codexInstallChainsExistingNotifyAndBacksUp() {
    let original = #"notify = [ "/apps/Sky.app/bin", "turn-ended" ]"#
    guard case let .updated(text, backup) = CodexHookConfig.install(configText: original, scriptPath: script) else {
        Issue.record("expected .updated"); return
    }
    #expect(backup == original)
    #expect(text.contains(#"notify = [ "\#(script)", "codex", "/apps/Sky.app/bin", "turn-ended" ]"#))
    #expect(CodexHookConfig.isInstalled(configText: text, scriptPath: script))
    // Uninstall restores the original verbatim.
    #expect(CodexHookConfig.uninstall(configText: text, backup: backup, scriptPath: script) == original)
}

@Test func codexInstallAddsNotifyWhenNoneAndIsIdempotent() {
    let cfg = "model = \"gpt-5\"\n[tui]\ntheme = \"dark\""
    guard case let .updated(text, backup) = CodexHookConfig.install(configText: cfg, scriptPath: script) else {
        Issue.record("expected .updated"); return
    }
    #expect(backup == "")
    #expect(text.contains(#"notify = [ "\#(script)", "codex" ]"#))
    #expect(CodexHookConfig.install(configText: text, scriptPath: script) == .alreadyInstalled)
    // Uninstall with empty backup removes our line entirely.
    let restored = CodexHookConfig.uninstall(configText: text, backup: backup, scriptPath: script)
    #expect(!CodexHookConfig.isInstalled(configText: restored, scriptPath: script))
}

// MARK: - Hermes

@Test func hermesInstallAppendsManagedBlock() {
    guard case let .updated(text) = HermesHookConfig.install(configText: "model: hermes-4\n", scriptPath: script) else {
        Issue.record("expected .updated"); return
    }
    #expect(text.contains("pre_approval_request:"))
    #expect(text.contains("\(script) emit hermes needsAttention"))
    #expect(HermesHookConfig.isInstalled(configText: text))
    // Uninstall removes the block, leaving the original content.
    let removed = HermesHookConfig.uninstall(configText: text)
    #expect(!HermesHookConfig.isInstalled(configText: removed))
    #expect(removed.contains("model: hermes-4"))
}

@Test func hermesReinstallReplacesBlockNotDuplicate() {
    let once = HermesHookConfig.install(configText: "", scriptPath: script)
    guard case let .updated(t1) = once else { Issue.record("expected .updated"); return }
    let twice = HermesHookConfig.install(configText: t1, scriptPath: script)
    guard case let .updated(t2) = twice else { Issue.record("expected .updated"); return }
    let occurrences = t2.components(separatedBy: HermesHookConfig.beginMarker).count - 1
    #expect(occurrences == 1)
}

@Test func hermesConflictsWithExistingHooks() {
    let result = HermesHookConfig.install(configText: "hooks:\n  on_session_end:\n    - command: mine\n", scriptPath: script)
    guard case let .conflict(snippet) = result else { Issue.record("expected .conflict"); return }
    #expect(snippet.contains("pre_approval_request:"))
}
