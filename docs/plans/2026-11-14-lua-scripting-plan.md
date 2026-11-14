# Lua scripting (init.lua) v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the `spike/lua` spike into the shipped v1 of `~/.config/zetty/init.lua` scripting: actions on keys and in ⌘K, four events, timers, a non-blocking `zetty.exec`, a Settings page and an error chip.

**Architecture:** The pure SwiftPM target `ZettyLua` (on vendored Lua 5.4.7, `CLua`) owns one Lua state, the prelude that builds the `zetty` table, timers (through an injected `LuaScheduler`) and shell commands (through an injected `LuaCommandRunner`). The app's `LuaScripting` is the `LuaHost`: every verb goes through `AppDelegate.handleOnMain(ControlRequest)`, the same path as the control socket. Workspace events come from a pure `PaneEventTracker` in ZettyCore, which diffs pane snapshots taken at `onWorkspaceDidChange` / `onActiveProjectChanged`.

**Tech Stack:** Swift 6 package / Swift 5 app target (Tuist), Lua 5.4.7 C sources, swift-testing, AppKit.

**Spec:** `docs/plans/2026-11-14-lua-scripting-design.md` (approved 2026-11-14). Read it first; this plan does not repeat its tables.

## Global Constraints

- Work in the worktree `/Users/inggo/AI/zetty/.claude/worktrees/spike-lua`, branch `spike/lua`. Another session owns the main checkout; never touch it.
- **No commits.** Glen commits on request only (CLAUDE.md). Each task ends with a checkpoint (tests green, build clean) instead of a commit.
- No `lua_error`/`luaL_error`/allocation failure may longjmp across a Swift frame that holds references. C entry points return `(nil, message)`; Lua wrappers raise. The count hook holds no Swift references.
- Lua 5.4 macros Swift can't import: `LUA_REGISTRYINDEX` = `-1_001_000`; first upvalue = `-1_001_001`; `lua_pcall` → `lua_pcallk(L,n,r,0,0,nil)`; `lua_pop(L,n)` → `lua_settop(L,-n-1)`; `lua_newtable` → `lua_createtable(L,0,0)`. `lua_gc` is variadic, so Swift can't call it; run `collectgarbage` from Lua instead.
- `ZettyCore` and `ZettyLua` import no AppKit.
- Values pinned by the spec: budget 2 s per call; memory cap 64 MB; `every` minimum 1 s; exec timeout default 30 s, SIGTERM then SIGKILL after 2 s; exec output cap 1 MB per stream, then `"\n[truncated]"`; at most 8 commands at once; output ring 50 lines; config key `zetty-scripting` (default `true`).
- Exact error texts: `"os.execute blocks Zetty; use zetty.exec(cmd, callback)"`, `"io.popen blocks Zetty; use zetty.exec(cmd, callback)"`, `"os.exit would quit Zetty; it is disabled in init.lua"`, `"script ran past its time budget and was stopped"`, `"script used more than its memory limit"`, `"zetty.every: interval must be at least 1 second"`, `"zetty.exec expects a command string or an array of strings"`, `"scripting is off (zetty-scripting = false)"`.
- After adding or removing an app file, run `mise exec -- tuist generate --no-open`. Build with `scripts/build.sh -derivedDataPath build`; zero new warnings. Package tests: `mise exec -- swift test --filter <name>`.
- Keep main's `Package.resolved` pin (libghostty 2.2.2026110702) in both workspace locations. A fresh resolve breaks `Ghostty.swift`.
- Verify the app only in the isolated test app (`.hydra/rules/isolated-test-app.md`, home `/tmp/zlua`, CLI wrapper `/private/tmp/claude-501/-Users-inggo-AI-zetty/9a0a9b0f-1bf7-4a27-818d-2aaa2f33b396/scratchpad/iz`). Never quit or replace `/Applications/zetty.app`. Never send keystrokes with system-wide tools; drive the test app through its own CLI.
- UI uses `ZTheme` tokens and `ZTheme.chromeFont` only, no hardcoded colors (`design-rules.md`, `DESIGN.md`). Status-bar refreshes go through `setNeedsChromeRefresh` (`chrome-refresh.md`).
- No debug `print`/`NSLog` left in the code.

## Review Focus

1. **A `pane.opened` handler that itself splits** should split once, not forever. Pinned by Task 5's `trackerAbsorbsChangesWithoutEmitting` and checked in Task 7's isolated-app run.
2. **`zetty.exec` on a command that leaves a background child holding stdout** (`"sleep 5 & echo hi"`) should call back as soon as the shell exits, not when the child does. Pinned by Task 3's `runnerDoesNotWaitForBackgroundChildren`.
3. **An action that calls itself through `zetty.run`** should fail with a Lua stack-overflow error and leave the state usable. Pinned by Task 1's `luaRecursiveActionFailsCleanly`.
4. **Command output that is not valid UTF-8** should come back with replacement characters, never a crash. Pinned by Task 3's `runnerDecodesInvalidUTF8`.
5. **Deleting `init.lua` while it is loaded** should leave no actions, bindings, timers or chip on the next reload. Pinned by Task 1's `luaReloadWithoutFileClearsEverything` and Task 2's `luaReloadCancelsTimers`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/ZettyLua/LuaRuntime.swift` (modify) | State lifecycle, load, calls in (`runAction`, `emit`, `eval`), budget and memory hook, internals refs, timers and exec bookkeeping |
| `Sources/ZettyLua/LuaPrelude.swift` (create) | The prelude Lua source (moved out of `LuaRuntime`) and `starterFile` |
| `Sources/ZettyLua/LuaStack.swift` (create) | `string`/`value`/`push` stack conversion (moved out, unchanged) |
| `Sources/ZettyLua/LuaScheduler.swift` (create) | `LuaScheduler`, `LuaCancellable`, `MainQueueScheduler` |
| `Sources/ZettyLua/LuaCommandRunner.swift` (create) | `LuaCommand`, `LuaCommandResult`, `LuaCommandRunner`, `ProcessCommandRunner` |
| `Sources/ZettyCore/Scripting/PaneEventTracker.swift` (create) | Pure diff of pane/project snapshots into `WorkspaceEvent`s |
| `Sources/ZettyCore/Support/ToolSearchPath.swift` (create) | The shared tool `PATH` list (from `FileViewerLoader.binaryDirectories`) |
| `Sources/ZettyCore/Config/AppConfig.swift` (modify) | `zetty-scripting` key |
| `Sources/ZettyCore/CLI/ControlProtocol.swift` (modify) | `.runAction` takes a foreground reading |
| `App/Sources/App/LuaScripting.swift` (modify) | `LuaHost`, verbs, state for Settings/chip, output ring, file watcher, event delivery |
| `App/Sources/App/AppDelegate.swift` (modify) | Wiring, manual vs automatic reload, `zetty-scripting` gate |
| `App/Sources/App/TerminalViewController.swift` (modify) | `paneRecords()` snapshot, chip passthrough |
| `App/Sources/App/SettingsWindowController.swift` (modify) | `Tab.scripting` and its page |
| `App/Sources/App/StatusBarView.swift` (modify) | "init.lua" warning chip |
| `App/Sources/App/FileViewerLoader.swift` (modify) | Use `ToolSearchPath` |
| `Tests/ZettyCoreTests/LuaRuntimeTests.swift`, `LuaCommandRunnerTests.swift`, `PaneEventTrackerTests.swift`, `AppConfigTests.swift`, ControlProtocol tests (modify/create) | Tests |
| `README.md`, `.hydra/rules/lua-scripting.md`, `.hydra/rules/configuration.md`, `.hydra/rules/control-cli.md`, `CLAUDE.md`/`AGENTS.md` index | Docs |

---

### Task 1: Harden the runtime (internals, blocked calls, modules, memory, source)

**Files:**
- Modify: `Sources/ZettyLua/LuaRuntime.swift`
- Create: `Sources/ZettyLua/LuaPrelude.swift`, `Sources/ZettyLua/LuaStack.swift`
- Test: `Tests/ZettyCoreTests/LuaRuntimeTests.swift`

**Interfaces:**
- Produces:
  - `protocol LuaHost: AnyObject { func luaCall(_ verb: String, _ argument: LuaValue) throws -> LuaValue; func luaLog(_ message: String); func luaReportError(_ message: String) }`. `luaReportError` receives handler, timer and exec-callback errors. Load errors stay in `errors`; action errors are returned.
  - `LuaRuntime.memoryLimit: Int` (default `64 * 1_048_576`), `LuaRuntime.configDirectory: String?` (set by `load`).
  - `LuaRuntime.shutdown()`: cancels timers and commands (Tasks 2–3) and closes the state; `actions`/`bindings` become empty.
  - Internals: the prelude **returns** a table `{ run, emit, manifest, render, fire, exec_done, gc }` instead of putting `_run` etc. on `zetty`. Swift keeps it with `luaL_ref(L, LUA_REGISTRYINDEX)` and reads it with `lua_rawgeti`.

- [ ] **Step 1: Write the failing tests** (add `func luaReportError(_ m: String) { reported.append(m) }` and `var reported: [String] = []` to `RecordingHost`)

```swift
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
    try #"return { greet = function() return "hi" end }"#.write(to: dir.appendingPathComponent("helpers.lua"), atomically: true, encoding: .utf8)
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
    #expect(runtime.runAction("loop", context: .table([:]))?.contains("stack overflow") == true)
    #expect(runtime.eval("1 + 1") == .success("2"))
}

@Test func luaReloadWithoutFileClearsEverything() {
    let runtime = load(#"zetty.action{ name = "a", run = function() end }; zetty.bind("d", "a")"#, host: RecordingHost())
    runtime.load(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).lua"))
    #expect(runtime.actions.isEmpty)
    #expect(runtime.bindings.isEmpty)
    #expect(runtime.errors.isEmpty)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `mise exec -- swift test --filter lua`
Expected: the compile fails on `luaReportError`, then the new tests fail. The 5 spike tests stay green once it compiles.

- [ ] **Step 3: Move the prelude to `LuaPrelude.swift` (`static let prelude` in an `extension LuaRuntime`) and the stack helpers to `LuaStack.swift`, unchanged.**

- [ ] **Step 4: Implement in the prelude and `LuaRuntime`:**
  - The prelude replaces `os.execute`, `io.popen` and `os.exit` with functions that `error(<exact text>, 2)`. Set `package.cpath = ""` and `package.path` to exactly `dir/?.lua;dir/?/init.lua`, or `""` with no dir.
  - The prelude returns the internals table. `zetty.run(name, ctx)` fills `ctx.source = ctx.source or "lua"`. `run` (internal) passes the Swift-given ctx through unchanged. `gc = function() collectgarbage("collect") end`.
  - Memory: right after `luaL_newstate`, before `luaL_openlibs`, install a counting allocator with `lua_setallocf`. It is a `realloc`/`free` wrapper, so it is compatible with blocks the default allocator made. Its `ud` is a heap-allocated `struct { var used: Int; var limit: Int }`, freed after `lua_close`. `used` is signed, since blocks freed from before the switch may make it dip. **The allocator never returns NULL for a size it can satisfy.** `budgetHook` also raises `"script used more than its memory limit"` when `used > limit`. Reach the counter through `lua_getallocf(L, &ud)`, not the extra space (the deadline owns it).
  - After `protectedCall` returns the memory message, call internals `gc`. Keep `memoryLimit` in sync with the counter struct.
  - A missing file: `replaceState(with: fresh)` clears actions, bindings and errors (it does today; keep it, and have it cancel timers and commands once Tasks 2–3 add them).

- [ ] **Step 5: Run the tests**

Run: `mise exec -- swift test --filter lua`
Expected: all pass (5 spike + 7 new).

- [ ] **Step 6: Keep the app building.** Add `func luaReportError(_ message: String) { ZettyLog.config.error("init.lua: \(message)") }` to `App/Sources/App/LuaScripting.swift` (Task 6 replaces it).

- [ ] **Step 7: Checkpoint**: `mise exec -- swift build` and `scripts/build.sh -derivedDataPath build` show no new warnings. No commit.

---

### Task 2: Timers (`zetty.after`, `zetty.every`)

**Files:**
- Create: `Sources/ZettyLua/LuaScheduler.swift`
- Modify: `Sources/ZettyLua/LuaRuntime.swift`, `Sources/ZettyLua/LuaPrelude.swift`
- Test: `Tests/ZettyCoreTests/LuaRuntimeTests.swift`

**Interfaces:**
- Consumes: the Task 1 internals table (`fire`), `LuaHost.luaReportError`.
- Produces:
  - `public protocol LuaCancellable: AnyObject { func cancel() }`
  - `public protocol LuaScheduler: AnyObject { func schedule(after seconds: TimeInterval, repeats: Bool, _ fire: @escaping () -> Void) -> LuaCancellable }`
  - `public final class MainQueueScheduler: LuaScheduler`, which uses a `DispatchSourceTimer` on `.main`.
  - `LuaRuntime.init(host: LuaHost, scheduler: LuaScheduler = MainQueueScheduler(), commands: LuaCommandRunner = ProcessCommandRunner(), baseEnvironment: [String: String] = ProcessInfo.processInfo.environment)`. Add `commands`/`baseEnvironment` in Task 3; keep the parameter order fixed now.
  - Runtime-internal verbs handled in `handleRaw` before the host: any verb starting with `_` (`_after`, `_cancel`) never reaches `LuaHost`.

- [ ] **Step 1: Write the failing tests** (test-file helper)

```swift
private final class ManualScheduler: LuaScheduler {
    final class Entry: LuaCancellable {
        let seconds: TimeInterval, repeats: Bool, fire: () -> Void
        var cancelled = false
        init(_ s: TimeInterval, _ r: Bool, _ f: @escaping () -> Void) { seconds = s; repeats = r; fire = f }
        func cancel() { cancelled = true }
    }
    var entries: [Entry] = []
    func schedule(after seconds: TimeInterval, repeats: Bool, _ fire: @escaping () -> Void) -> LuaCancellable {
        let entry = Entry(seconds, repeats, fire); entries.append(entry); return entry
    }
    func fireLive() { for entry in entries where !entry.cancelled { entry.fire() } }
}

@Test func luaAfterFiresOnce() { /* load `zetty.after(5, function() print("tick") end)` with a ManualScheduler;
    #expect(scheduler.entries.map(\.seconds) == [5]); #expect(scheduler.entries[0].repeats == false)
    scheduler.fireLive(); scheduler.fireLive(); #expect(host.logs == ["tick"]) */ }

@Test func luaEveryRepeatsAndRejectsShortIntervals() { /* `zetty.every(2, function() print("t") end)`: repeats == true;
    fireLive() twice → logs == ["t", "t"].
    Separate load of `zetty.every(0.5, function() end)` → errors.first contains "zetty.every: interval must be at least 1 second" */ }

@Test func luaTimerHandleCancels() { /* `local h = zetty.after(1, function() print("x") end); h:cancel()`
    → entries[0].cancelled == true; fireLive() → logs == [] */ }

@Test func luaReloadCancelsTimers() { /* load with after+every, then runtime.load(fileURL: missing)
    → every entry cancelled; also runtime.shutdown() on a fresh load cancels its entries */ }

@Test func luaTimerErrorIsReportedAndOthersKeepRunning() { /* two `every(1, …)`, the first `error("boom")`, the second prints
    → after fireLive(): host.reported.count == 1 and contains "boom"; host.logs == ["ok"] */ }
```

Write the bodies as the comments describe, building the runtime as `LuaRuntime(host: host, scheduler: scheduler)` (extend the `load` helper with a `scheduler:` parameter).

- [ ] **Step 2: Run them and confirm they fail**: `mise exec -- swift test --filter lua`. Expected: the compile fails on `LuaScheduler`.

- [ ] **Step 3: Implement.**
  - Lua side: `zetty.after(seconds, fn)` / `zetty.every(seconds, fn)` validate their arguments and call `raw("_after", { seconds, repeats })`, which returns an integer id. They store `callbacks[id] = { fn, repeats }` and return a handle whose `:cancel()` calls `raw("_cancel", id)` and clears the entry. Internals `fire(id)` runs the callback (dropping it first when one-shot) with `pcall`. On error it returns the message, so Swift can pass it to `luaReportError`.
  - Swift side: `timers: [Int: LuaCancellable]`. The scheduled closure captures the runtime **weakly** plus the state pointer at scheduling time; it does nothing if the state has since been replaced. The fire runs internals `fire` through `protectedCall` (budget applies).
  - Every state replacement and `shutdown()` cancels and clears `timers`.

- [ ] **Step 4: Run the tests**: `mise exec -- swift test --filter lua`. Expected: all pass.

- [ ] **Step 5: Checkpoint**: no new warnings. No commit.

---

### Task 3: `zetty.exec` and `ProcessCommandRunner`

**Files:**
- Create: `Sources/ZettyLua/LuaCommandRunner.swift`, `Tests/ZettyCoreTests/LuaCommandRunnerTests.swift`
- Modify: `Sources/ZettyLua/LuaRuntime.swift`, `Sources/ZettyLua/LuaPrelude.swift`, `Tests/ZettyCoreTests/LuaRuntimeTests.swift`

**Interfaces:**
- Consumes: `LuaCancellable` (Task 2), internals `exec_done` (Task 1), `luaReportError`.
- Produces:
  - `public struct LuaCommand: Equatable, Sendable { public enum Program: Equatable, Sendable { case shell(String), argv([String]) }; public var program: Program; public var cwd: String; public var timeout: TimeInterval; public var environment: [String: String] }`
  - `public struct LuaCommandResult: Equatable, Sendable { public var code: Int32; public var stdout: String; public var stderr: String; public var timedOut: Bool }`
  - `public protocol LuaCommandRunner: AnyObject { func run(_ command: LuaCommand, completion: @escaping (LuaCommandResult) -> Void) -> LuaCancellable }`
  - `public final class ProcessCommandRunner: LuaCommandRunner { public init(maxConcurrent: Int = 8, outputCap: Int = 1_048_576, killGrace: TimeInterval = 2, deliverOn: DispatchQueue = .main) }`

- [ ] **Step 1: Write the failing runner tests** (real processes, `deliverOn` a private serial queue, awaited with `withCheckedContinuation`; helper `run(_ program:, cwd: = NSTemporaryDirectory(), timeout: = 30, env: = [:], runner: = ProcessCommandRunner(deliverOn: q)) async -> (LuaCommandResult, TimeInterval)`)

```swift
@Test func runnerReportsCodeAndBothStreams() async {
    let (r, _) = await run(.shell("printf hi; printf err >&2; exit 3"))
    #expect(r == LuaCommandResult(code: 3, stdout: "hi", stderr: "err", timedOut: false))
}
@Test func runnerRunsArgvWithoutAShell() async { #expect(await run(.argv(["/bin/echo", "a b"])).0.stdout == "a b\n") }
@Test func runnerHonoursCwdAndEnvironment() async {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    #expect(await run(.shell("pwd"), cwd: dir).0.stdout == dir + "\n")
    #expect(await run(.shell("echo $ZX"), env: ["ZX": "1"]).0.stdout == "1\n")
}
@Test func runnerTimesOut() async {
    let (r, elapsed) = await run(.shell("sleep 10"), timeout: 0.3)
    #expect(r.timedOut); #expect(elapsed < 3)
}
@Test func runnerDoesNotWaitForBackgroundChildren() async {
    let (r, elapsed) = await run(.shell("sleep 5 & echo hi"))
    #expect(r.stdout == "hi\n"); #expect(elapsed < 2)
}
@Test func runnerCapsOutput() async {
    let (r, _) = await run(.shell("yes | head -c 100"), runner: ProcessCommandRunner(outputCap: 16, deliverOn: q))
    #expect(r.stdout == String(repeating: "y\n", count: 8) + "\n[truncated]")
}
@Test func runnerDecodesInvalidUTF8() async { #expect(await run(.shell(#"printf '\377ok'"#)).0.stdout.hasSuffix("ok")) }
@Test func runnerQueuesPastTheConcurrencyCap() async { /* maxConcurrent 2, three `sleep 0.5` started together →
    the last completion arrives ≥ 0.9 s after the start */ }
@Test func runnerCancelDropsTheCompletion() async { /* run `sleep 10`, cancel at once, wait 1 s → completion never called */ }
```

- [ ] **Step 2: Write the failing runtime tests** with a `FakeRunner` that records `LuaCommand`s, returns `ManualScheduler.Entry`-style cancellables, and exposes `complete(index, result)`:
  - `luaExecPassesCommandAndDefaults`: `zetty.exec("git status", function(r) print(r.code, r.stdout, r.timed_out) end)` → `runner.commands[0] == LuaCommand(program: .shell("git status"), cwd: <config dir>, timeout: 30, environment: <baseEnvironment>)`. `complete(0, .init(code: 0, stdout: "ok", stderr: "", timedOut: false))` → `host.logs == ["0 ok false"]`.
  - `luaExecReadsOptions`: `zetty.exec({"ls", "-la"}, { cwd = "~/x", timeout = 5, env = { A = "b" } }, fn)` → `.argv(["ls","-la"])`, cwd `NSHomeDirectory() + "/x"`, timeout 5, environment = base merged with `A=b`.
  - `luaExecRejectsBadCommands`: `zetty.exec(42, function() end)` raises `"zetty.exec expects a command string or an array of strings"`.
  - `luaReloadDropsCommandCallbacks`: start exec, reload, then `complete(0, …)` → nothing logged, and the fake's cancellable `cancelled == true`.
  - `luaExecCallbackErrorIsReported`: callback `error("bad")` → `host.reported` contains "bad".

- [ ] **Step 3: Run them and confirm they fail**: `mise exec -- swift test --filter "lua|runner"`. Expected: the compile fails on `LuaCommand`.

- [ ] **Step 4: Implement `ProcessCommandRunner`.**
  - Spawn with `posix_spawn` and `POSIX_SPAWN_SETPGROUP` (pgroup 0), so a timeout signals the whole group. `Process` can't set a group.
  - `.shell(s)` → `/bin/sh -c s`; `.argv` → `argv[0]` resolved against the command's `PATH`. stdin is `/dev/null`.
  - Read both pipes on a background queue. **Finish when the spawned process exits**, then drain whatever is already readable for at most 0.25 s and stop reading. This is what makes the background-child test pass.
  - Timeout: `kill(-pgid, SIGTERM)`, then `SIGKILL` after `killGrace`. `timedOut = true`, `code` = the exit status, or 128+signal for a signal.
  - Cap: keep the first `outputCap` bytes of each stream, drop the rest, and append `"\n[truncated]"` when anything was dropped. Decode with `String(decoding:as: UTF8.self)`.
  - Concurrency: a FIFO queue; at most `maxConcurrent` processes running.
  - `cancel()`: a queued command is removed; a running one is signalled like a timeout. Its completion is never called.
  - Completion runs on `deliverOn`.

- [ ] **Step 5: Implement the Lua side.**
  - `zetty.exec(cmd, opts?, fn)` validates `cmd` (string, or a non-empty array of strings), `opts` (`cwd` string, `timeout` > 0, `env` string→string) and `fn`. It calls `raw("_exec", { cmd, cwd, timeout, env })` → id, stores the callback, and returns a handle with `:cancel()` (→ `raw("_cancel_exec", id)`).
  - Swift side: build the `LuaCommand` (tilde-expand `cwd`; default `configDirectory ?? NSHomeDirectory()`; `baseEnvironment` merged with `env`) and keep `commands: [Int: LuaCancellable]`.
  - On completion (if the state is unchanged), call internals `exec_done(id, { code, stdout, stderr, timed_out })` through `protectedCall`, and pass an error to `luaReportError`. Cancel everything on replace/`shutdown`, as with timers.

- [ ] **Step 6: Run the tests**: `mise exec -- swift test --filter "lua|runner"`. Expected: all pass. Run them 3 times to catch flaky timing.

- [ ] **Step 7: Checkpoint**: no new warnings. No commit.

---

### Task 4: `zetty-scripting` config key

**Files:**
- Modify: `Sources/ZettyCore/Config/AppConfig.swift`
- Test: `Tests/ZettyCoreTests/AppConfigTests.swift`

**Interfaces:**
- Produces: `AppConfig.scripting: Bool` (default `true`), parsed from `zetty-scripting`, rendered in `rendered()`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func scriptingIsZettysOwnAndDefaultsOn() {
    #expect(AppConfig.parse("").scripting)
    let off = AppConfig.parse("zetty-scripting = off")
    #expect(!off.scripting)
    #expect(off.rendered().contains("zetty-scripting = false"))
    #expect(AppConfig.parse(off.rendered()).scripting == false)
    #expect(AppConfig.parse(AppConfig.parse("").rendered()).scripting)
}
```

- [ ] **Step 2: Run it and confirm it fails**: `mise exec -- swift test --filter scriptingIsZettysOwnAndDefaultsOn`. Expected: the compile fails.

- [ ] **Step 3: Implement.** Follow `zetty-hibernate-handoffs` exactly: a property with a doc comment, the init default, the `case "zetty-scripting":` parse (`["true","yes","on","1"]`), and a rendered block with the comment `# Run ~/.config/zetty/init.lua (actions, key bindings, event handlers). Off loads nothing.`

- [ ] **Step 4: Run it**: `mise exec -- swift test --filter AppConfig`. Expected: all pass.

- [ ] **Step 5: Checkpoint.** No commit. (The Settings switch lands in Task 8.)

---

### Task 5: `PaneEventTracker`

**Files:**
- Create: `Sources/ZettyCore/Scripting/PaneEventTracker.swift`, `Tests/ZettyCoreTests/PaneEventTrackerTests.swift`

**Interfaces:**
- Produces:
  - `public struct PaneRecord: Equatable, Sendable { public var pane: String; public var project: String; public var cwd: String? }`. `pane` is the 8-hex short id.
  - `public enum WorkspaceEvent: Equatable, Sendable { case paneOpened(PaneRecord); case paneClosed(pane: String, project: String); case projectFocused(project: String, previous: String?) }`
  - `public final class PaneEventTracker { public init(); public func update(panes: [PaneRecord], activeProject: String?, emit: Bool) -> [WorkspaceEvent] }`

- [ ] **Step 1: Write the failing tests**

```swift
private let a = PaneRecord(pane: "aaaa0001", project: "web", cwd: "/w")
private let b = PaneRecord(pane: "bbbb0002", project: "web", cwd: "/w")
private let c = PaneRecord(pane: "cccc0003", project: "api", cwd: nil)

@Test func trackerFirstUpdateIsABaseline() {
    #expect(PaneEventTracker().update(panes: [a, b], activeProject: "web", emit: true).isEmpty)
}
@Test func trackerReportsClosedThenOpenedThenFocus() {
    let t = PaneEventTracker()
    _ = t.update(panes: [a, b], activeProject: "web", emit: true)
    #expect(t.update(panes: [a, c], activeProject: "api", emit: true) == [
        .paneClosed(pane: "bbbb0002", project: "web"),
        .paneOpened(c),
        .projectFocused(project: "api", previous: "web"),
    ])
}
@Test func trackerIgnoresUnchangedAndCwdOnlyChanges() {
    let t = PaneEventTracker()
    _ = t.update(panes: [a], activeProject: "web", emit: true)
    var moved = a; moved.cwd = "/elsewhere"
    #expect(t.update(panes: [moved], activeProject: "web", emit: true).isEmpty)
}
@Test func trackerAbsorbsChangesWithoutEmitting() {
    let t = PaneEventTracker()
    _ = t.update(panes: [a], activeProject: "web", emit: true)
    #expect(t.update(panes: [a, b], activeProject: "web", emit: false).isEmpty)
    #expect(t.update(panes: [a, b], activeProject: "web", emit: true).isEmpty)
}
```

- [ ] **Step 2: Run them and confirm they fail**: `mise exec -- swift test --filter tracker`.

- [ ] **Step 3: Implement.** Panes are keyed by `pane`. Closed panes come out in previous-snapshot order, opened ones in new-snapshot order, focus last. `emit: false` moves the baseline and returns `[]`.

- [ ] **Step 4: Run them**: `mise exec -- swift test --filter tracker`. Expected: pass.

- [ ] **Step 5: Checkpoint.** No commit.

---

### Task 6: App host: verbs, safety, reload, state

**Files:**
- Create: `Sources/ZettyCore/Support/ToolSearchPath.swift`
- Modify: `App/Sources/App/LuaScripting.swift`, `App/Sources/App/AppDelegate.swift`, `App/Sources/App/FileViewerLoader.swift`, `Sources/ZettyCore/CLI/ControlProtocol.swift`
- Test: the ControlProtocol test file holding the `refusesBusyPanes`/`takesForegroundReading` tests (grep `takesForegroundReading` under `Tests/`), plus a new `toolSearchPathLeadsWithZettyAndHomebrew` in a Support test file

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces:
  - `public enum ToolSearchPath { public static func directories(home: String = NSHomeDirectory()) -> [String] }`, returning `[home/.zetty/bin, /opt/homebrew/bin, /usr/local/bin, home/.local/bin, /usr/bin, /bin]`.
  - `LuaScripting`:
    - `init(perform: @escaping (ControlRequest) -> ControlResponse, foregroundGate: LuaForegroundGate)`
    - `func reload(enabled: Bool)`
    - `func run(_ name: String, source: String) -> String?`
    - `func emit(_ event: String, _ payload: [String: LuaValue])`
    - `func eval(_ code: String) -> ControlResponse`
    - `func applyingBindings(to: KeyBindingConfiguration) -> KeyBindingConfiguration`
    - `var isRunningLua: Bool`
    - `var state: LuaScriptingState`
    - `static let didChangeNotification: Notification.Name`
    - `static var fileURL: URL`
  - `struct LuaScriptingState { var enabled: Bool; var fileExists: Bool; var loadedAt: Date?; var actions: [(name: String, title: String, chord: String?)]; var errors: [String]; var output: [String] }`. `errors` holds the load errors plus handler/timer/exec/action errors since the last load. `output` is the last 50 `print`/log lines.
  - `protocol LuaForegroundGate: AnyObject { var cliForegroundReading: BusyPaneGate.Reading? { get set } }`. `TerminalViewController` conforms.

- [ ] **Step 1: Write the failing ZettyCore tests**

```swift
@Test func runActionTakesAForegroundReading() {
    #expect(ControlRequest.runAction(name: "dev").takesForegroundReading)
    #expect(!ControlRequest.luaEval(code: "1").takesForegroundReading)
}
@Test func toolSearchPathLeadsWithZettyAndHomebrew() {
    #expect(ToolSearchPath.directories(home: "/h") == ["/h/.zetty/bin", "/opt/homebrew/bin", "/usr/local/bin", "/h/.local/bin", "/usr/bin", "/bin"])
}
```

- [ ] **Step 2: Run them and confirm they fail**: `mise exec -- swift test --filter "runActionTakesAForegroundReading|toolSearchPath"`.

- [ ] **Step 3: Implement the ZettyCore parts.** `takesForegroundReading` returns true for `.runAction`. Add `ToolSearchPath`, and point `FileViewerLoader.binaryDirectories` at it.

- [ ] **Step 4: Implement `LuaScripting`.**
  - Build the runtime with `baseEnvironment` = `ProcessInfo.processInfo.environment` with `PATH = ToolSearchPath.directories().joined(":") + ":" + existing PATH`.
  - `isRunningLua` is true for the length of every call into the runtime (run, emit, eval, and timer/exec callbacks: wrap `protectedCall` entry through a host hook, or set it in `LuaScripting` around each entry and in `luaCall`).
  - `run(_:source:)` builds ctx `{ pane, cwd, project, source }`, as the spike does, plus `source`.
  - `close` verb: when `force` is false, `foregroundGate.cliForegroundReading == nil` and `!NSApp.isActive`, set the reading to `.failed` for that one call and restore it afterwards. In error text from `close`, replace `"--force"` with `"force = true"`.
  - Every `luaLog` line goes to `ZettyLog.config` and the 50-line ring. `luaReportError` and action errors go to `ZettyLog.config.error` and `state.errors`. Post `didChangeNotification` (coalesced to one per run-loop turn) whenever `state` changes.
  - `reload(enabled: false)` → `runtime.shutdown()` and state "off". `run`/`eval` then answer `"scripting is off (zetty-scripting = false)"`, and `applyingBindings` returns its input.
  - `init.lua` watcher: a second `ConfigFileWatcher(url: LuaScripting.fileURL)` started by `LuaScripting`. Its change → `reload(enabled:)` + re-apply bindings (through a `onBindingsChanged` callback that AppDelegate sets).

- [ ] **Step 5: Wire `AppDelegate`.**
  - `perform` = save `isServingControlRequest`, set it true, call `handleOnMain`, restore it.
  - Split reload: `reloadConfiguration(_:)` (menu ⇧⌘, at line ~3021, `tvc.onReloadConfig` at ~213, `zetty reload` at ~2511) reloads Lua and then the flat config. The config watcher (~459) and `onConfigSaved` (~1685) call a new `applyConfigFromDisk()`, which re-reads the flat config and re-merges the **existing** Lua bindings without re-running `init.lua`.
  - `zetty-scripting` toggled in the flat config → `reload(enabled:)` from `applyConfigFromDisk()` only when the value changed.
  - Pass `source` through: `"key"` from `scriptActionHandler`, `"palette"` from ⌘K, `"cli"` from `.runAction`.
  - ⌘K entries (`tvc.scriptPaletteCommands`) set `kbd` to the action's prefix chord, written the way the palette shows other prefix bindings, instead of the spike's `""`.

- [ ] **Step 6: Build**: `mise exec -- tuist generate --no-open && scripts/build.sh -derivedDataPath build`. Expected: success, zero warnings. `mise exec -- swift test` → all pass.

- [ ] **Step 7: Verify in the isolated test app** (rebuild `/tmp/zlua/zetty.app` from `build/`, relaunch per `isolated-test-app.md`). Use `/tmp/zlua/.config/zetty/init.lua` from the spike plus:
  - `zetty.action{ name = "gh", run = function() zetty.exec({"gh","--version"}, function(r) print(r.code, r.stdout) end) end }`
  - `zetty.action{ name = "bad", run = function() io.popen("ls") end }`
  - `zetty.every(1, function() n = (n or 0) + 1 end)`

  Expected:
  - `iz do gh` returns at once, and the log shows `0 gh version …`.
  - `iz do bad` exits 1 with the `io.popen` message.
  - `iz lua n` grows between calls.
  - Editing `init.lua` reloads it within ~1 s with no `iz reload`.
  - `iz do close-busy` (an action calling `zetty.close{ pane = <a pane running sleep 100> }`) is refused and names `force = true`.
  - Setting `zetty-scripting = false` in the test config → `iz do gh` answers `scripting is off (zetty-scripting = false)`.
  - The real app's zmx session count is unchanged.

- [ ] **Step 8: Checkpoint.** No commit.

---

### Task 7: Events: `pane.opened`, `pane.closed`, `project.focused`

**Files:**
- Modify: `App/Sources/App/TerminalViewController.swift`, `App/Sources/App/AppDelegate.swift`, `App/Sources/App/LuaScripting.swift`

**Interfaces:**
- Consumes: `PaneEventTracker`, `WorkspaceEvent`, `PaneRecord` (Task 5); `LuaScripting.isRunningLua`, `emit` (Task 6).
- Produces: `TerminalViewController.paneRecords() -> (panes: [PaneRecord], activeProject: String?)`, covering awake projects only (the same set as `allSurfaceIDs`) from `workspace.projects`, so the remote view (`dropRemoteProject`) and hibernated projects are excluded. Short ids come from `SessionPersistence.shortID(for:)`; cwd comes from the same source `zetty status` uses for a pane.

- [ ] **Step 1: Implement the snapshot and wiring.**
  - At startup, after the workspace restore and before any user input, call `tracker.update(…, emit: false)` once as the baseline.
  - Hook both `tvc.onWorkspaceDidChange` (keep its `scheduleSave()`) and `tvc.onActiveProjectChanged` (keep `applyThemeForActiveProject()`; chain, don't replace).
  - Each hook takes the snapshot **synchronously** and calls `update(…, emit: !luaScripting.isRunningLua)`. It then delivers the returned events with `DispatchQueue.main.async`, mapped to:
    - `pane.opened {pane, project, cwd}`
    - `pane.closed {pane, project}`
    - `project.focused {project, previous}`
  - Skip delivery while scripting is off.

- [ ] **Step 2: Build**: `mise exec -- tuist generate --no-open && scripts/build.sh -derivedDataPath build`. Expected: zero warnings.

- [ ] **Step 3: Verify in the isolated test app** with handlers that `print` each event's `zetty.inspect(e)`:
  - `iz split` → exactly one `pane.opened` with the right project and cwd.
  - `iz close --pane <id>` → one `pane.closed`.
  - `iz new-tab` → one `pane.opened`.
  - Switching project (`iz focus` a pane in another project) → one `project.focused` with `previous`.
  - Hibernating a project → one `pane.closed` per pane; waking it → one `pane.opened` per pane.
  - Quitting the test app with `iz quit` (sessions preserved) and relaunching → **no** `pane.opened`.
  - A handler `zetty.on("pane.opened", function(e) zetty.split{ pane = e.pane } end)` followed by one `iz split` → exactly two new panes, then it stops (Review Focus 1).
  - If any structural change produces no event, find the TVC path that skips `onWorkspaceDidChange` and add the call there; note it in `lua-scripting.md`.

- [ ] **Step 4: Checkpoint.** No commit.

---

### Task 8: Settings → Scripting, the status-bar chip, the starter file

**Files:**
- Modify: `App/Sources/App/SettingsWindowController.swift`, `App/Sources/App/StatusBarView.swift`, `App/Sources/App/TerminalViewController.swift`, `App/Sources/App/AppDelegate.swift`, `Sources/ZettyLua/LuaPrelude.swift`
- Test: `Tests/ZettyCoreTests/LuaRuntimeTests.swift`

**Interfaces:**
- Consumes: `LuaScripting.state`, `didChangeNotification`, `reload`, `fileURL` (Task 6); `AppConfig.scripting` (Task 4).
- Produces:
  - `LuaRuntime.starterFile: String`
  - `SettingsWindowController.Tab.scripting` (title "Scripting", symbol `["curlybraces", "chevron.left.forwardslash.chevron.right"]`, a palette hue not used by its neighbours)
  - `StatusBarView.setScriptWarning(_ visible: Bool)` and `var onScriptWarningClicked: (() -> Void)?`

- [ ] **Step 1: Write the failing test**

```swift
@Test func luaStarterFileLoadsClean() {
    let host = RecordingHost()
    let runtime = load(LuaRuntime.starterFile, host: host)
    #expect(runtime.errors.isEmpty)
    #expect(runtime.actions.count == 1)
    #expect(runtime.bindings.count == 1)
}
```

- [ ] **Step 2: Run it and confirm it fails**: `mise exec -- swift test --filter luaStarterFileLoadsClean`.

- [ ] **Step 3: Write `starterFile`.** It is a commented file: one action, one `zetty.bind("prefix>…")` on a chord that is free in the default prefix table (check `KeyBindingConfiguration` defaults), and one `zetty.on("agent.status", …)` handler. Each part has a one-line comment, and the file links the README's Scripting section.

- [ ] **Step 4: Build the Scripting page** (same file as the other pages, since `switchRow`/`sectionHeader`/`caption` are `private`). It contains, top to bottom:
  - the `zetty-scripting` switch (`updateConfig { $0.scripting = … }`);
  - the file path, with **Open in Editor** (reuse the existing open-config-in-editor path), **Reload** (`reload` + re-apply bindings), and **Create init.lua** shown only when the file is missing (it writes `starterFile`, then opens it in the editor);
  - a status line: `Loaded at HH:MM · N actions · N bindings`, `Not loaded`, or `Off`;
  - the errors, verbatim (they carry file:line), in the error color token;
  - the actions with their chords;
  - the last 50 output lines in a scrollable mono text view.

  The page refreshes on `didChangeNotification` while it is visible. Update the `hue` doc comment's page count.

- [ ] **Step 5: Add the chip.**
  - Model it on the CLI-reinstall pill in `StatusBarView`: hidden by default, text `init.lua`, with the warning token.
  - `TerminalViewController` forwards `setScriptWarning` and requests a status-bar refresh through `setNeedsChromeRefresh(statusBar: true)`.
  - AppDelegate observes `didChangeNotification` → `setScriptWarning(!state.errors.isEmpty)`. A click → `openSettings(tab: .scripting)`.

- [ ] **Step 6: Build and test**: `mise exec -- swift test --filter lua` passes. `scripts/build.sh -derivedDataPath build` gives zero warnings.

- [ ] **Step 7: Verify in the isolated test app.**
  - Break `init.lua` (a syntax error) → the chip appears within ~1 s, and Settings → Scripting shows the error with its line while the old actions still run.
  - Fix it → the chip clears.
  - Delete `init.lua` → **Create init.lua** appears; clicking it writes the starter, which loads with 1 action and 1 binding.
  - Toggling the switch writes `zetty-scripting` and the page shows `Off`.
  - Glen checks the parts no CLI can reach: the ⌘K entry, the prefix key, and the page's look.

- [ ] **Step 8: Checkpoint.** No commit.

---

### Task 9: Docs

**Files:**
- Modify: `README.md`, `.hydra/rules/configuration.md`, `.hydra/rules/control-cli.md`, `CLAUDE.md` + `AGENTS.md` (index rows only, via `hydra sync`)
- Create: `.hydra/rules/lua-scripting.md`

- [ ] **Step 1: README.**
  - Add a "Scripting (experimental)" section under Using Zetty: the file location, a 6-line example (an action, a bind, an `on`), the API and events in one short table each, `zetty.exec` with the note that `os.execute`/`io.popen` are disabled, and `zetty do` / `zetty lua`.
  - Add `zetty-scripting` to Configuration, and `do`/`lua` to the Control CLI list.

- [ ] **Step 2: `.hydra/rules/lua-scripting.md`.**
  - Frontmatter paths: `Sources/ZettyLua/**`, `Sources/CLua/**`, `App/Sources/App/LuaScripting.swift`, `Sources/ZettyCore/Scripting/**`. Commands: `zetty do`, `zetty lua`.
  - Body:
    - the longjmp rule and why the allocator never fails;
    - the budget and memory hook;
    - the internals table in the registry;
    - timers and exec bookkeeping, with cancel on reload;
    - the process-group spawn and finish-on-exit rule;
    - the event choke points, plus the "script-caused changes don't emit" rule;
    - manual vs automatic reload;
    - how to add a verb (`luaCall` case + prelude list + README) and an event (tracker or call site + README table);
    - the Lua macro table from Global Constraints.

  Then run `hydra sync` and confirm `CLAUDE.md` and `AGENTS.md` are still byte-identical (`cmp CLAUDE.md AGENTS.md`).

- [ ] **Step 3: `configuration.md`.** Add a `zetty-scripting` bullet. `control-cli.md`: add `do`/`lua`, and note that `.runAction` takes a foreground reading.

- [ ] **Step 4: Grep for stale names**: `grep -rn "spike\|SPIKE" Sources/ZettyLua App/Sources/App/LuaScripting.swift Project.swift` and `grep -rn "_run\|_emit\|_manifest\|_render" Sources/ZettyLua`. Expected: no hits except intended ones. Change the design doc's status line to `approved 2026-11-14`.

- [ ] **Step 5: Checkpoint.** No commit.

---

### Task 10: Final verification

- [ ] **Step 1:** Run `mise exec -- swift test` and confirm all pass. Run `scripts/build.sh -derivedDataPath build` and confirm zero warnings.
- [ ] **Step 2:** Run through the spec's Testing section in the isolated test app once more, from a fresh `/tmp/zlua` home: each event, keep-last-good, the budget stop (`spin`), the memory stop (`iz lua "local t={} for i=1,1e9 do t[i]=('x'):rep(100)..i end"` → the memory message, and `iz lua 1+1` → `2` after), `zetty-scripting = false`, and exec timeout via `zetty.exec("sleep 60", { timeout = 1 }, …)` → `timed_out true`.
- [ ] **Step 3:** Confirm the real app is untouched (same zmx session count as at the start), then tear down: `iz quit --kill-sessions --force`, `rm -rf /tmp/zlua`.
- [ ] **Step 4:** Report to Glen: what was verified, what only Glen can check (⌘K entry, prefix key press, notification banner, page look), and that nothing is committed.
