import Foundation
import Testing
@testable import ZettyLua

private final class RecordingHost: LuaHost {
    var calls: [(String, LuaValue)] = []
    var logs: [String] = []
    var reported: [String] = []
    func luaCall(_ verb: String, _ argument: LuaValue) throws -> LuaValue {
        calls.append((verb, argument))
        if verb == "close" { throw LuaHostError("no such pane") }
        return verb == "split" ? .string("abcd1234") : .null
    }
    func luaLog(_ message: String) { logs.append(message) }
    func luaReportError(_ message: String) { reported.append(message) }
}

/// Fires timers on demand instead of on a clock.
private final class ManualScheduler: LuaScheduler {
    final class Entry: LuaCancellable {
        let seconds: TimeInterval, repeats: Bool, fire: () -> Void
        var cancelled = false
        init(_ seconds: TimeInterval, _ repeats: Bool, _ fire: @escaping () -> Void) {
            self.seconds = seconds; self.repeats = repeats; self.fire = fire
        }
        func cancel() { cancelled = true }
    }
    var entries: [Entry] = []
    func schedule(after seconds: TimeInterval, repeats: Bool, _ fire: @escaping () -> Void) -> LuaCancellable {
        let entry = Entry(seconds, repeats, fire)
        entries.append(entry)
        return entry
    }
    func fireLive() { for entry in entries where !entry.cancelled { entry.fire() } }
}

private func writeTemporary(_ source: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-lua-\(UUID().uuidString).lua")
    try! source.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Records commands; the test decides when each one finishes.
private final class FakeRunner: LuaCommandRunner {
    final class Handle: LuaCancellable {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    var commands: [LuaCommand] = []
    var handles: [Handle] = []
    private var completions: [(LuaCommandResult) -> Void] = []
    func run(_ command: LuaCommand, completion: @escaping (LuaCommandResult) -> Void) -> LuaCancellable {
        commands.append(command)
        completions.append(completion)
        let handle = Handle()
        handles.append(handle)
        return handle
    }
    func complete(_ index: Int, _ result: LuaCommandResult) { completions[index](result) }
}

private let testEnvironment = ["PATH": "/usr/bin:/bin", "HOME": "/h"]

private func load(_ source: String, host: RecordingHost,
                  scheduler: LuaScheduler = ManualScheduler(),
                  runner: LuaCommandRunner = FakeRunner()) -> LuaRuntime {
    let url = writeTemporary(source)
    defer { try? FileManager.default.removeItem(at: url) }
    let runtime = LuaRuntime(host: host, scheduler: scheduler, commands: runner, baseEnvironment: testEnvironment)
    runtime.load(fileURL: url)
    return runtime
}

private let missingFile = FileManager.default.temporaryDirectory
    .appendingPathComponent("zetty-lua-missing-\(UUID().uuidString).lua")

@Test func luaActionsBindingsAndVerbsReachTheHost() {
    let host = RecordingHost()
    let runtime = load("""
    zetty.action{ name = "dev", title = "Start Dev", run = function(ctx)
      local p = zetty.split{ pane = ctx.pane, direction = "right" }
      zetty.send{ pane = p, text = "npm run dev", enter = true }
    end }
    zetty.bind("prefix>d", "dev")
    print("loaded", 1)
    """, host: host)
    #expect(runtime.errors.isEmpty)
    #expect(runtime.actions == [.init(name: "dev", title: "Start Dev")])
    #expect(runtime.bindings == [.init(chord: "prefix>d", action: "dev")])
    #expect(host.logs == ["loaded 1"])

    #expect(runtime.runAction("dev", context: .table(["pane": .string("ffff0000")])) == nil)
    #expect(host.calls.map(\.0) == ["split", "send"])
    #expect(host.calls[0].1 == .table(["pane": .string("ffff0000"), "direction": .string("right")]))
    #expect(host.calls[1].1["pane"] == .string("abcd1234"))
    #expect(host.calls[1].1["enter"] == .bool(true))
}

@Test func luaHostErrorsRaiseAtTheCaller() {
    let host = RecordingHost()
    let runtime = load("""
    zetty.action{ name = "bad", run = function() zetty.close{ pane = "x" } end }
    """, host: host)
    let error = runtime.runAction("bad", context: .table([:]))
    #expect(error?.contains("zetty.close: no such pane") == true)
}

@Test func luaSyntaxErrorKeepsThePreviousConfig() {
    let host = RecordingHost()
    let runtime = load(#"zetty.action{ name = "a", run = function() end }"#, host: host)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zetty-lua-bad.lua")
    try! "zetty.action{ name = ".write(to: url, atomically: true, encoding: .utf8)
    runtime.load(fileURL: url)
    #expect(runtime.errors.count == 1)
    #expect(runtime.actions.map(\.name) == ["a"])
}

@Test func luaRunawayLoopIsStopped() throws {
    let host = RecordingHost()
    let runtime = load(#"zetty.action{ name = "spin", run = function() while true do end end }"#, host: host)
    runtime.budget = 0.2
    let error = runtime.runAction("spin", context: .null)
    #expect(error?.contains("time budget") == true)
    // The state survives the stop.
    #expect(try runtime.eval("1 + 1").get() == "2")
}

@Test func luaEvalRendersTables() throws {
    let host = RecordingHost()
    let runtime = load("", host: host)
    #expect(try runtime.eval("{ 1, 2, name = 'x' }").get() == #"{ 1, 2, name = "x" }"#)
    #expect(try runtime.eval("'plain'").get() == "plain")
    #expect(try runtime.eval("x = 5").get() == "")
    #expect(try runtime.eval("x").get() == "5")
}

@Test func luaNilingZettyDoesNotBreakTheApp() {
    let host = RecordingHost()
    let runtime = load(#"zetty.action{ name = "a", run = function() print("ran") end }; zetty = nil"#, host: host)
    #expect(runtime.errors.isEmpty)
    #expect(runtime.actions.map(\.name) == ["a"])
    #expect(runtime.runAction("a", context: .table([:])) == nil)
    #expect(host.logs == ["ran"])
    #expect(runtime.eval("1 + 1") == .success("2"))
}

@Test func luaBlockingCallsRaise() {
    let runtime = load("", host: RecordingHost())
    // error(msg, 2) prefixes the caller's position ("eval:1: "), so match the tail.
    func message(_ code: String) -> String {
        if case .failure(let e) = runtime.eval(code) { return e.message }
        return "no error"
    }
    #expect(message("os.execute('true')").hasSuffix("os.execute blocks Zetty; use zetty.exec(cmd, callback)"))
    #expect(message("io.popen('true')").hasSuffix("io.popen blocks Zetty; use zetty.exec(cmd, callback)"))
    #expect(message("os.exit(0)").hasSuffix("os.exit would quit Zetty; it is disabled in init.lua"))
}

@Test func luaLoadsPlainModulesFromTheConfigDirectoryOnly() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zetty-lua-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try #"return { greet = function() return "hi" end }"#
        .write(to: dir.appendingPathComponent("helpers.lua"), atomically: true, encoding: .utf8)
    try #"H = require("helpers")"#.write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    let runtime = LuaRuntime(host: RecordingHost())
    runtime.load(fileURL: dir.appendingPathComponent("init.lua"))
    #expect(runtime.errors.isEmpty)
    #expect(runtime.eval("H.greet()") == .success("hi"))
    #expect(runtime.eval("package.cpath") == .success(""))
    #expect(runtime.eval("package.path") == .success("\(dir.path)/?.lua;\(dir.path)/?/init.lua"))
}

@Test func luaMemoryLimitStopsTheCallAndRecovers() {
    let runtime = load("", host: RecordingHost())
    runtime.memoryLimit = 8 * 1_048_576
    let result = runtime.eval("local t = {} for i = 1, 1e8 do t[i] = string.rep('x', 100) .. i end")
    #expect(result == .failure(LuaHostError("script used more than its memory limit")))
    #expect(runtime.eval("1 + 1") == .success("2"))
}

@Test func luaContextSourceDefaultsToLuaForNestedRuns() {
    let host = RecordingHost()
    let runtime = load("""
    zetty.action{ name = "a", run = function(ctx) print(ctx.source) end }
    zetty.action{ name = "b", run = function() zetty.run("a") end }
    """, host: host)
    runtime.runAction("a", context: .table(["source": .string("key")]))
    runtime.runAction("b", context: .table(["source": .string("palette")]))
    #expect(host.logs == ["key", "lua"])
}

@Test func luaRecursiveActionFailsCleanly() {
    let runtime = load(#"zetty.action{ name = "loop", run = function() zetty.run("loop") end }"#, host: RecordingHost())
    // Lua's 1M-slot stack costs more than the 64 MB cap, so the memory stop
    // usually comes first; either way the call ends with an error.
    let message = runtime.runAction("loop", context: .table([:])) ?? "no error"
    #expect(message.contains("stack overflow") || message == "script used more than its memory limit", "\(message)")
    #expect(runtime.eval("1 + 1") == .success("2"))
}

@Test func luaReloadWithoutFileClearsEverything() {
    let runtime = load(#"zetty.action{ name = "a", run = function() end }; zetty.bind("d", "a")"#, host: RecordingHost())
    runtime.load(fileURL: missingFile)
    #expect(runtime.actions.isEmpty)
    #expect(runtime.bindings.isEmpty)
    #expect(runtime.errors.isEmpty)
}

// MARK: - Timers

@Test func luaAfterFiresOnce() {
    let host = RecordingHost(), scheduler = ManualScheduler()
    let runtime = load(#"zetty.after(5, function() print("tick") end)"#, host: host, scheduler: scheduler)
    #expect(scheduler.entries.map(\.seconds) == [5])
    #expect(scheduler.entries[0].repeats == false)
    // Timers hold the runtime weakly: one that is gone fires nothing.
    withExtendedLifetime(runtime) {
        scheduler.fireLive()
        scheduler.fireLive()
    }
    #expect(host.logs == ["tick"])
}

@Test func luaEveryRepeatsAndRejectsShortIntervals() {
    let host = RecordingHost(), scheduler = ManualScheduler()
    let runtime = load(#"zetty.every(2, function() print("t") end)"#, host: host, scheduler: scheduler)
    #expect(scheduler.entries.map(\.repeats) == [true])
    withExtendedLifetime(runtime) {
        scheduler.fireLive()
        scheduler.fireLive()
    }
    #expect(host.logs == ["t", "t"])

    let fast = load("zetty.every(0.5, function() end)", host: RecordingHost())
    #expect(fast.errors.first?.contains("zetty.every: interval must be at least 1 second") == true)
}

@Test func luaTimerHandleCancels() {
    let host = RecordingHost(), scheduler = ManualScheduler()
    let runtime = load(#"local h = zetty.after(1, function() print("x") end); h:cancel()"#, host: host, scheduler: scheduler)
    #expect(scheduler.entries[0].cancelled)
    withExtendedLifetime(runtime) { scheduler.fireLive() }
    #expect(host.logs.isEmpty)
}

@Test func luaReloadCancelsTimers() {
    let scheduler = ManualScheduler()
    let runtime = load("""
    zetty.after(5, function() end)
    zetty.every(5, function() end)
    """, host: RecordingHost(), scheduler: scheduler)
    runtime.load(fileURL: missingFile)
    #expect(scheduler.entries.count == 2)
    #expect(scheduler.entries.map(\.cancelled) == [true, true])

    let other = ManualScheduler()
    let second = load("zetty.every(5, function() end)", host: RecordingHost(), scheduler: other)
    second.shutdown()
    #expect(other.entries.map(\.cancelled) == [true])
}

@Test func luaTimerErrorIsReportedAndOthersKeepRunning() {
    let host = RecordingHost(), scheduler = ManualScheduler()
    let runtime = load("""
    zetty.every(1, function() error("boom") end)
    zetty.every(1, function() print("ok") end)
    """, host: host, scheduler: scheduler)
    withExtendedLifetime(runtime) { scheduler.fireLive() }
    #expect(host.reported.count == 1)
    #expect(host.reported.first?.contains("boom") == true)
    #expect(host.logs == ["ok"])
}

// MARK: - zetty.exec

@Test func luaExecPassesCommandAndDefaults() {
    let host = RecordingHost(), runner = FakeRunner()
    let runtime = load(#"""
    zetty.exec("git status", function(r) print(r.code, r.stdout, r.timed_out) end)
    """#, host: host, runner: runner)
    #expect(runtime.errors.isEmpty)
    #expect(runner.commands == [LuaCommand(program: .shell("git status"), cwd: runtime.configDirectory!,
                                           timeout: 30, environment: testEnvironment)])
    withExtendedLifetime(runtime) {
        runner.complete(0, LuaCommandResult(code: 0, stdout: "ok", stderr: "", timedOut: false))
    }
    #expect(host.logs == ["0 ok false"])
}

@Test func luaExecReadsOptions() {
    let runner = FakeRunner()
    let runtime = load(#"""
    zetty.exec({ "ls", "-la" }, { cwd = "~/x", timeout = 5, env = { A = "b" } }, function() end)
    """#, host: RecordingHost(), runner: runner)
    #expect(runtime.errors.isEmpty)
    var environment = testEnvironment
    environment["A"] = "b"
    #expect(runner.commands == [LuaCommand(program: .argv(["ls", "-la"]), cwd: NSHomeDirectory() + "/x",
                                           timeout: 5, environment: environment)])
}

@Test func luaExecRejectsBadCommands() {
    let runtime = load("zetty.exec(42, function() end)", host: RecordingHost())
    #expect(runtime.errors.first?.contains("zetty.exec expects a command string or an array of strings") == true)
}

@Test func luaReloadDropsCommandCallbacks() {
    let host = RecordingHost(), runner = FakeRunner()
    let runtime = load(#"zetty.exec("true", function() print("late") end)"#, host: host, runner: runner)
    runtime.load(fileURL: missingFile)
    #expect(runner.handles.map(\.cancelled) == [true])
    withExtendedLifetime(runtime) {
        runner.complete(0, LuaCommandResult(code: 0, stdout: "", stderr: "", timedOut: false))
    }
    #expect(host.logs.isEmpty)
}

@Test func luaExecCallbackErrorIsReported() {
    let host = RecordingHost(), runner = FakeRunner()
    let runtime = load(#"zetty.exec("true", function() error("bad") end)"#, host: host, runner: runner)
    withExtendedLifetime(runtime) {
        runner.complete(0, LuaCommandResult(code: 0, stdout: "", stderr: "", timedOut: false))
    }
    #expect(host.reported.count == 1)
    #expect(host.reported.first?.contains("bad") == true)
}

// MARK: - Starter file

@Test func luaStarterFileLoadsClean() {
    let host = RecordingHost()
    let runtime = load(LuaRuntime.starterFile, host: host)
    #expect(runtime.errors.isEmpty)
    #expect(runtime.actions.count == 1)
    #expect(runtime.bindings.count == 1)
}

// MARK: - Final review fixes

/// A retry loop catches the budget error with pcall; the stop must still
/// unwind to the top instead of looping forever on the main thread.
@Test(.timeLimit(.minutes(1))) func luaPcallLoopIsStopped() {
    let runtime = load("""
    zetty.action{ name = "retry", run = function()
      while true do pcall(function() for j = 1, 1e6 do end end) end
    end }
    """, host: RecordingHost())
    runtime.budget = 0.3
    let start = Date()
    let error = runtime.runAction("retry", context: .table([:]))
    #expect(error?.contains("time budget") == true)
    #expect(Date().timeIntervalSince(start) < 3)
    #expect(runtime.eval("1 + 1") == .success("2"))
}

/// A coroutine made in one call and resumed in a later one runs under the
/// later call's budget, not the one it was created in.
@Test func luaCoroutineResumedLaterGetsFreshBudget() {
    let url = writeTemporary("""
    co = coroutine.create(function()
      while true do for i = 1, 30000 do end coroutine.yield("ran") end
    end)
    """)
    defer { try? FileManager.default.removeItem(at: url) }
    let runtime = LuaRuntime(host: RecordingHost(), scheduler: ManualScheduler(), commands: FakeRunner())
    runtime.budget = 0.3
    runtime.load(fileURL: url)
    Thread.sleep(forTimeInterval: 0.5)
    #expect(runtime.eval("coroutine.resume(co)") == .success("true\tran"))
}

/// A handler that hits the memory cap inside emit's own pcall must not leave
/// the state failing every later call.
@Test func luaMemoryStopInHandlerRecovers() {
    let host = RecordingHost()
    let runtime = load("""
    zetty.on("big", function() local t = {} for i = 1, 1e8 do t[i] = ("x"):rep(100) .. i end end)
    zetty.on("tick", function() local x = 0 for i = 1, 30000 do x = x + i end TICK = x end)
    """, host: host)
    runtime.memoryLimit = 8 * 1_048_576
    runtime.emit("big", payload: .null)
    #expect(host.reported.count == 1)
    for _ in 0..<5 { runtime.emit("tick", payload: .null) }
    #expect(host.reported.count == 1)
    #expect(runtime.eval("TICK") == .success("450015000"))
}
