import Foundation
import Testing
@testable import ZettyCore

@Test func claudeCompactsWithHandoffInstructionsAndCodexWithout() throws {
    let claude = try #require(HandoffCompaction.line(for: .claude))
    #expect(claude.hasPrefix("/compact Write this summary as a handoff"))
    for phrase in ["remembers nothing", "full path", "next steps", "secrets"] {
        #expect(claude.contains(phrase), "\(phrase)")
    }
    #expect(HandoffCompaction.line(for: .codex) == "/compact")
    #expect(HandoffCompaction.line(for: .gemini) == nil)
    #expect(HandoffCompaction.supports(.claude) && HandoffCompaction.supports(.codex))
    #expect(!HandoffCompaction.supports(.aider))
}

// It is typed into a prompt box. A newline would submit half of it, and a
// long paste is folded into a chip the slash command would take as its
// whole argument.
@Test func theLineIsOneShortLine() throws {
    let line = try #require(HandoffCompaction.line(for: .claude))
    #expect(!line.contains("\n"))
    #expect(line.count < 500)
}

@Test func aCompactionIsFinishedWhenTheTranscriptSaysSo() {
    let claudeDone = """
        {"type":"user","message":{"role":"user","content":"/compact Write this summary as a handoff"}}
        {"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}
        """
    #expect(HandoffCompaction.hasCompacted(agent: .claude, appended: claudeDone))
    let codexDone = """
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"compacted","payload":{"message":"…"}}
        """
    #expect(HandoffCompaction.hasCompacted(agent: .codex, appended: codexDone))
}

// The request itself contains the word, and so can anything the person
// typed; only the harness's own marker counts.
@Test func theRequestAloneIsNotACompaction() {
    let asked = #"{"type":"user","message":{"role":"user","content":"/compact please, compact_boundary"}}"#
    #expect(!HandoffCompaction.hasCompacted(agent: .claude, appended: asked))
    #expect(!HandoffCompaction.hasCompacted(agent: .codex, appended: asked))
    #expect(!HandoffCompaction.hasCompacted(agent: .claude, appended: #"{"type":"compacted"}"#))
    #expect(!HandoffCompaction.hasCompacted(agent: .claude, appended: "compact\n{half a line"))
    #expect(!HandoffCompaction.hasCompacted(agent: .gemini, appended: #"{"type":"compacted"}"#))
}

// MARK: - Already a handoff

private let claudeBoundary = #"{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}"#
private let claudeSummary = #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"Summary"}}"#
private let claudeReply = #"{"type":"assistant","message":{"role":"assistant","content":[]}}"#

// Woken and put away again with nothing said in between. Asked to compact,
// Claude answers "Not enough messages to compact" and writes no marker,
// which once read as a failure and left the project awake.
@Test func aConversationCompactedAndNotAddedToNeedsNoCompaction() {
    let compact = [claudeReply, claudeBoundary, claudeSummary].joined(separator: "\n")
    #expect(!HandoffCompaction.needsCompaction(agent: .claude, transcriptTail: compact))
    // The person typing is not the agent replying: still nothing to compact.
    let asked = compact + "\n" + #"{"type":"user","message":{"role":"user","content":"hello?"}}"#
    #expect(!HandoffCompaction.needsCompaction(agent: .claude, transcriptTail: asked))
    let codex = #"{"type":"compacted","payload":{}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
    #expect(!HandoffCompaction.needsCompaction(agent: .codex, transcriptTail: codex))
}

@Test func oneThatHasGrownSinceOrWasNeverCompactedDoes() {
    let grown = [claudeBoundary, claudeSummary, claudeReply].joined(separator: "\n")
    #expect(HandoffCompaction.needsCompaction(agent: .claude, transcriptTail: grown))
    #expect(HandoffCompaction.needsCompaction(agent: .claude, transcriptTail: claudeReply))
    // Only the LAST compaction counts.
    let twice = [claudeBoundary, claudeReply, claudeBoundary, claudeSummary].joined(separator: "\n")
    #expect(!HandoffCompaction.needsCompaction(agent: .claude, transcriptTail: twice))
    let codex = #"{"type":"compacted","payload":{}}"# + "\n"
        + #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#
    #expect(HandoffCompaction.needsCompaction(agent: .codex, transcriptTail: codex))
}

