import Foundation
import Testing
@testable import ZettyCore

private let claude = UUID(), codex = UUID(), shell = UUID()

private func preparation(awaiting: Set<UUID> = [claude, codex]) -> HibernationPreparation {
    HibernationPreparation(panes: [claude, codex, shell], awaiting: awaiting, isAutomatic: false)
}

@Test func aProjectIsPutAwayOnlyOnceEveryAgentHasCompacted() {
    var preparing = preparation()
    #expect(preparing.finish(claude, .compacted) == nil)
    #expect(preparing.isWriting(claude), "done, and waiting on the other")
    #expect(preparing.finish(codex, .compacted) == .putAway([claude, codex]))
}

@Test func oneFailureLeavesTheProjectAwake() {
    var preparing = preparation()
    #expect(preparing.finish(claude, .failed("its prompt box holds a draft")) == .leftAwake(failed: claude))
}

@Test func aPaneNotWaitedOnChangesNothing() {
    var preparing = preparation()
    #expect(preparing.finish(shell, .compacted) == nil)
    #expect(!preparing.isWriting(shell))
    // Reporting twice is not two answers.
    _ = preparing.finish(claude, .compacted)
    #expect(preparing.finish(claude, .failed("late")) == nil)
}

// A cleared chat has a session and nothing to summarise. It is skipped, and
// skipping it is not a failure; it comes back as a plain shell.
@Test func panesWithNothingToHandOffAreNoFailure() {
    var preparing = preparation()
    #expect(preparing.finish(codex, .skipped) == nil)
    #expect(preparing.finish(claude, .compacted) == .putAway([claude]))

    var nothing = preparation()
    _ = nothing.finish(claude, .skipped)
    #expect(nothing.finish(codex, .skipped) == .putAway([]))
}

@Test func aPaneAddedOrClosedSinceEndsTheAttempt() {
    let preparing = preparation()
    #expect(preparing.describes([shell, codex, claude]))
    #expect(!preparing.describes([claude, codex]))
    #expect(!preparing.describes([claude, codex, shell, UUID()]))
}

// MARK: - Is there a conversation to hand off

@Test func aClaudeTranscriptHasAConversationOnceClaudeHasReplied() {
    let cleared = """
        {"type":"last-prompt","sessionId":"s"}
        {"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-stdout></local-command-stdout>"}}
        """
    #expect(!HandoffConversation.hasReply(agent: .claude, transcript: cleared))
    let replied = cleared + "\n" + #"{"type":"assistant","message":{"role":"assistant","content":[]}}"#
    #expect(HandoffConversation.hasReply(agent: .claude, transcript: replied))
}

@Test func aCodexRolloutHasAConversationOnceCodexHasReplied() {
    let fresh = """
        {"type":"session_meta","payload":{"id":"s","cwd":"/p"}}
        {"type":"response_item","payload":{"type":"message","role":"developer","content":[]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[]}}
        """
    #expect(!HandoffConversation.hasReply(agent: .codex, transcript: fresh))
    let replied = fresh + "\n"
        + #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#
    #expect(HandoffConversation.hasReply(agent: .codex, transcript: replied))
}

// The person quoting the word, or a line that is not JSON, is not a reply.
@Test func onlyARealReplyCounts() {
    let quoted = #"{"type":"user","message":{"role":"user","content":"is \"type\":\"assistant\" a thing?"}}"#
    #expect(!HandoffConversation.hasReply(agent: .claude, transcript: quoted))
    #expect(!HandoffConversation.hasReply(agent: .claude, transcript: "assistant\n{broken"))
    #expect(!HandoffConversation.hasReply(agent: .gemini, transcript: #"{"type":"assistant"}"#))
}

// MARK: - What a handoff is called

// A pane that was never on screen reported no title, and three handoffs in
// one project were listed as "Claude", "Claude", "Claude".
@Test func aClaudeConversationIsNamedByItsLatestTitle() {
    let transcript = """
        {"type":"ai-title","aiTitle":"Importer review"}
        {"type":"user","message":{"role":"user","content":"what is an ai-title?"}}
        {"type":"ai-title","aiTitle":"Importer.swift retry logic"}
        {"type":"last-prompt","lastPrompt":"/compact"}
        """
    #expect(HandoffConversation.title(agent: .claude, transcriptTail: transcript) == "Importer.swift retry logic")
    #expect(HandoffConversation.title(agent: .claude, transcriptTail: #"{"type":"ai-title","aiTitle":"  "}"#) == nil)
    #expect(HandoffConversation.title(agent: .claude, transcriptTail: #"{"type":"user"}"#) == nil)
    // Codex records none.
    #expect(HandoffConversation.title(agent: .codex, transcriptTail: transcript) == nil)
}

