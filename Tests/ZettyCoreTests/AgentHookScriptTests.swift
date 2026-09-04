import Foundation
import Testing
@testable import ZettyCore

/// Runs the generated hook helper with python3 in a scratch HOME and returns the
/// sink lines it wrote. `stdin` is the harness payload; `extraEnv` the pane env.
private func runHook(args: [String], stdin: String, extraEnv: [String: String]) throws -> [String] {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-hook-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appendingPathComponent("zetty-hook.py")
    try AgentHookScript.contents.write(to: script, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [script.path] + args
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = dir.path          // SINK is ~/.zetty/agent-events.jsonl
    env["ZETTY"] = "1"
    env.removeValue(forKey: "ZETTY_SURFACE")
    env.removeValue(forKey: "ZETTY_CWD_FILE")
    for (k, v) in extraEnv { env[k] = v }
    process.environment = env
    let input = Pipe()
    process.standardInput = input
    try process.run()
    input.fileHandleForWriting.write(stdin.data(using: .utf8)!)
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    let sink = dir.appendingPathComponent(".zetty/agent-events.jsonl")
    let text = (try? String(contentsOf: sink, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
}

@Test func hookEmitsSurfaceFromZettySurfaceAndClaudeSessionID() throws {
    let lines = try runHook(
        args: ["emit", "claude", "running"],
        stdin: #"{"session_id":"8d1e2b6c-aaaa-4bbb-8ccc-000000000002","cwd":"/p"}"#,
        extraEnv: ["ZETTY_SURFACE": "5F0C2A1E-0000-4000-8000-000000000001"])
    let line = try #require(lines.last)
    let event = try #require(AgentEvent.parse(line: line))
    #expect(event.cwd == "/p")
    #expect(event.surface == UUID(uuidString: "5F0C2A1E-0000-4000-8000-000000000001"))
    #expect(event.session == "8d1e2b6c-aaaa-4bbb-8ccc-000000000002")
}

@Test func hookDerivesSurfaceFromCwdFileStemForOlderPanes() throws {
    let lines = try runHook(
        args: ["emit", "claude", "idle"],
        stdin: #"{"cwd":"/p"}"#,
        extraEnv: ["ZETTY_CWD_FILE": "/Users/x/.zetty/panes/5F0C2A1E-0000-4000-8000-000000000009.cwd"])
    let line = try #require(lines.last)
    let event = try #require(AgentEvent.parse(line: line))
    #expect(event.surface == UUID(uuidString: "5F0C2A1E-0000-4000-8000-000000000009"))
    #expect(event.session == nil)
}

@Test func hookEmitsCodexThreadIDAsSession() throws {
    let payload = #"{"type":"agent-turn-complete","thread-id":"019a2b3c-dddd-4eee-8fff-000000000003","cwd":"/q"}"#
    // No chained notify program → the helper only emits.
    let lines = try runHook(args: ["codex", payload], stdin: "", extraEnv: [:])
    let line = try #require(lines.last)
    let event = try #require(AgentEvent.parse(line: line))
    #expect(event.agent == .codex)
    #expect(event.cwd == "/q")
    #expect(event.session == "019a2b3c-dddd-4eee-8fff-000000000003")
}

@Test func hookLegacyLineShapeStillParsesWithoutPaneEnv() throws {
    let lines = try runHook(args: ["emit", "claude", "idle"], stdin: #"{"cwd":"/p"}"#, extraEnv: [:])
    let line = try #require(lines.last)
    let event = try #require(AgentEvent.parse(line: line))
    #expect(event.surface == nil)
    #expect(event.session == nil)
}
