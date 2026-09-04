import Foundation
import Testing
@testable import ZettyCore

private let p1 = UUID(uuidString: "5F0C2A1E-0000-4000-8000-000000000001")!
private let p2 = UUID(uuidString: "5F0C2A1E-0000-4000-8000-000000000002")!
private let p3 = UUID(uuidString: "5F0C2A1E-0000-4000-8000-000000000003")!

// MARK: - Claude slug

@Test func claudeSlugReplacesSeparatorsAndSpaces() {
    #expect(AgentSessionStore.claudeProjectSlug(forCwd: "/Users/g/AI/zetty") == "-Users-g-AI-zetty")
    // A space is slugged exactly like a separator (verified against the real store).
    #expect(AgentSessionStore.claudeProjectSlug(forCwd: "/Users/g/NL Generator") == "-Users-g-NL-Generator")
    // Dashes survive; dots and underscores become dashes.
    #expect(AgentSessionStore.claudeProjectSlug(forCwd: "/Users/g/AI/nl-generator") == "-Users-g-AI-nl-generator")
    #expect(AgentSessionStore.claudeProjectSlug(forCwd: "/Users/g/.config/my_app") == "-Users-g--config-my-app")
}

@Test func transcriptFileNameYieldsItsSessionID() {
    #expect(AgentSessionStore.sessionID(fromTranscriptFileName: "c26b5353-80ff-4e4f-a205-641dbb99eeaa.jsonl")
            == "c26b5353-80ff-4e4f-a205-641dbb99eeaa")
    #expect(AgentSessionStore.sessionID(fromTranscriptFileName: "notes.txt") == nil)
    #expect(AgentSessionStore.sessionID(fromTranscriptFileName: ".jsonl") == nil)
    // A name that would not be shell-safe is refused, so it can never reach a command.
    #expect(AgentSessionStore.sessionID(fromTranscriptFileName: "a'; rm -rf ~.jsonl") == nil)
}

@Test func transcriptLineYieldsRecordedCwdForValidatingTheSlugGuess() {
    let line = #"{"type":"user","cwd":"/Users/g/AI/zetty","sessionId":"abc"}"#
    #expect(AgentSessionStore.cwd(fromTranscriptLine: line) == "/Users/g/AI/zetty")
    // Lines without a cwd (e.g. Claude's `last-prompt` entry) simply yield nil.
    #expect(AgentSessionStore.cwd(fromTranscriptLine: #"{"sessionId":"abc","type":"last-prompt"}"#) == nil)
    #expect(AgentSessionStore.cwd(fromTranscriptLine: "not json") == nil)
    #expect(AgentSessionStore.cwd(fromTranscriptLine: "") == nil)
}

// MARK: - Codex

@Test func codexRolloutFirstLineYieldsIDAndCwd() {
    let line = #"{"timestamp":"2026-09-04T11:38:06Z","payload":{"id":"0199b42a-2c17-7241-873c-4e45a8a26e16","cwd":"/Users/g/Herd/bundyv3","cli_version":"0.42.0"}}"#
    let rollout = AgentSessionStore.codexRollout(fromFirstLine: line)
    #expect(rollout?.id == "0199b42a-2c17-7241-873c-4e45a8a26e16")
    #expect(rollout?.cwd == "/Users/g/Herd/bundyv3")
}

@Test func codexRolloutRejectsIncompleteOrUnsafeLines() {
    #expect(AgentSessionStore.codexRollout(fromFirstLine: #"{"payload":{"id":"abc"}}"#) == nil)          // no cwd
    #expect(AgentSessionStore.codexRollout(fromFirstLine: #"{"payload":{"cwd":"/p"}}"#) == nil)          // no id
    #expect(AgentSessionStore.codexRollout(fromFirstLine: #"{"id":"abc","cwd":"/p"}"#) == nil)           // not under payload
    #expect(AgentSessionStore.codexRollout(fromFirstLine: #"{"payload":{"id":"a b","cwd":"/p"}}"#) == nil)  // unsafe id
    #expect(AgentSessionStore.codexRollout(fromFirstLine: "garbage") == nil)
}

// MARK: - Assignment

@Test func assignHandsNewestCandidateToEachPaneInOrder() {
    let got = AgentSessionStore.assign(panes: [p1, p2], candidates: ["newest", "older", "oldest"])
    #expect(got == [p1: "newest", p2: "older"])
}

@Test func assignNeverRepeatsAConversationAndStopsWhenCandidatesRunOut() {
    let got = AgentSessionStore.assign(panes: [p1, p2, p3], candidates: ["only"])
    #expect(got == [p1: "only"])   // p2/p3 get nothing rather than a duplicate
}

@Test func assignSkipsSessionsAlreadyClaimedByAHook() {
    // p1's id came from its hook; the guess for p2 must not reuse it.
    let got = AgentSessionStore.assign(panes: [p2], candidates: ["hook-owned", "free"],
                                       excluding: ["hook-owned"])
    #expect(got == [p2: "free"])
}

@Test func assignWithNoPanesOrNoCandidatesYieldsNothing() {
    #expect(AgentSessionStore.assign(panes: [], candidates: ["a"]).isEmpty)
    #expect(AgentSessionStore.assign(panes: [p1], candidates: []).isEmpty)
    #expect(AgentSessionStore.assign(panes: [p1], candidates: ["a"], excluding: ["a"]).isEmpty)
}
