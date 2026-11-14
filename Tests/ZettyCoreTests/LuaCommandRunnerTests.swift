import Foundation
import Testing
@testable import ZettyLua

private let delivery = DispatchQueue(label: "runner-tests")

/// Runs one command and waits for its result. Returns it with the seconds it took.
private func run(_ program: LuaCommand.Program, cwd: String = NSTemporaryDirectory(), timeout: TimeInterval = 30,
                 env: [String: String] = [:],
                 runner: ProcessCommandRunner = ProcessCommandRunner(deliverOn: delivery))
    async -> (LuaCommandResult, TimeInterval) {
    let start = Date()
    let command = LuaCommand(program: program, cwd: cwd, timeout: timeout,
                             environment: ProcessInfo.processInfo.environment.merging(env) { _, new in new })
    let result: LuaCommandResult = await withCheckedContinuation { continuation in
        _ = runner.run(command) { continuation.resume(returning: $0) }
    }
    return (result, Date().timeIntervalSince(start))
}

@Test func runnerReportsCodeAndBothStreams() async {
    let (result, _) = await run(.shell("printf hi; printf err >&2; exit 3"))
    #expect(result == LuaCommandResult(code: 3, stdout: "hi", stderr: "err", timedOut: false))
}

@Test func runnerRunsArgvWithoutAShell() async {
    #expect(await run(.argv(["/bin/echo", "a b"])).0.stdout == "a b\n")
}

@Test func runnerHonoursCwdAndEnvironment() async {
    // realpath, not resolvingSymlinksInPath: Foundation strips the /private prefix.
    let dir = String(cString: realpath(NSTemporaryDirectory(), nil))
    #expect(await run(.shell("pwd"), cwd: dir).0.stdout == dir + "\n")
    #expect(await run(.shell("echo $ZX"), env: ["ZX": "1"]).0.stdout == "1\n")
}

@Test func runnerTimesOut() async {
    let (result, elapsed) = await run(.shell("sleep 10"), timeout: 0.3)
    #expect(result.timedOut)
    #expect(elapsed < 3)
}

@Test func runnerDoesNotWaitForBackgroundChildren() async {
    let (result, elapsed) = await run(.shell("sleep 5 & echo hi"))
    #expect(result.stdout == "hi\n")
    #expect(elapsed < 2)
}

@Test func runnerCapsOutput() async {
    let (result, _) = await run(.shell("yes | head -c 100"),
                                runner: ProcessCommandRunner(outputCap: 16, deliverOn: delivery))
    #expect(result.stdout == String(repeating: "y\n", count: 8) + "\n[truncated]")
}

@Test func runnerDecodesInvalidUTF8() async {
    #expect(await run(.shell(#"printf '\377ok'"#)).0.stdout.hasSuffix("ok"))
}

@Test func runnerQueuesPastTheConcurrencyCap() async {
    let runner = ProcessCommandRunner(maxConcurrent: 2, deliverOn: delivery)
    let start = Date()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<3 {
            group.addTask { _ = await run(.shell("sleep 0.5"), runner: runner) }
        }
    }
    #expect(Date().timeIntervalSince(start) >= 0.9)
}

@Test func runnerCancelDropsTheCompletion() async throws {
    let runner = ProcessCommandRunner(deliverOn: delivery)
    let called = Flag()
    let command = LuaCommand(program: .shell("sleep 10"), cwd: NSTemporaryDirectory(), timeout: 30,
                             environment: ProcessInfo.processInfo.environment)
    let handle = runner.run(command) { _ in called.set() }
    handle.cancel()
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(!called.isSet)
}

/// Quitting cancels running commands and the app may exit milliseconds later,
/// so cancel must signal the process itself rather than leave it to the next
/// poll. A one-second poll makes the difference visible.
@Test func runnerCancelSignalsARunningProcessAtOnce() async throws {
    let pidFile = NSTemporaryDirectory() + "zetty-runner-\(UUID().uuidString).pid"
    defer { try? FileManager.default.removeItem(atPath: pidFile) }
    let runner = ProcessCommandRunner(pollInterval: 1, deliverOn: delivery)
    let command = LuaCommand(program: .shell("echo $$ > \(pidFile); exec sleep 30"), cwd: NSTemporaryDirectory(),
                             timeout: 60, environment: ProcessInfo.processInfo.environment)
    let handle = runner.run(command) { _ in }
    var pid: pid_t = 0
    for _ in 0..<100 where pid == 0 {
        try await Task.sleep(nanoseconds: 20_000_000)
        pid = pid_t((try? String(contentsOfFile: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }
    #expect(pid > 0)
    handle.cancel()
    try await Task.sleep(nanoseconds: 100_000_000)
    // Gone, or a zombie waiting to be reaped: either way it was signalled.
    let stat = processState(pid)
    #expect(stat.isEmpty || stat.hasPrefix("Z"), "process state: \(stat)")
    kill(pid, SIGKILL)
}

@Test func runnerResolvesRelativeProgramsAgainstCwd() async throws {
    let dir = NSTemporaryDirectory() + "zetty-runner-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let script = dir + "/build.sh"
    try "#!/bin/sh\necho built\n".write(toFile: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    let (result, _) = await run(.argv(["./build.sh"]), cwd: dir)
    #expect(result.code == 0)
    #expect(result.stdout == "built\n")
}

/// `ps -o stat=` for `pid`: "" once it no longer exists.
private func processState(_ pid: pid_t) -> String {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "stat=", "-p", String(pid)]
    let pipe = Pipe()
    ps.standardOutput = pipe
    ps.standardError = Pipe()
    try? ps.run()
    ps.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
