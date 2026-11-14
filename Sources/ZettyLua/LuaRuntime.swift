import CLua
import Foundation

/// What the Lua side can ask of the app. `luaCall` answers `zetty.<verb>(…)`;
/// a thrown `LuaHostError` becomes a Lua error at the caller's line.
public protocol LuaHost: AnyObject {
    func luaCall(_ verb: String, _ argument: LuaValue) throws -> LuaValue
    func luaLog(_ message: String)
    /// An error from an event handler, timer or `zetty.exec` callback: code
    /// that ran with no caller to hand the error back to.
    func luaReportError(_ message: String)
}

public struct LuaHostError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// One Lua state running `init.lua`. Single-threaded: create and call it from
/// one thread (the app uses main).
///
/// The `zetty` table is built in Lua (`prelude`) on two C entry points,
/// `raw(verb, arg)` and `log(text)`. Errors are raised from Lua, never from a
/// Swift frame, so nothing longjmps across Swift code. For the same reason
/// the allocator never fails: the memory cap is enforced by the count hook.
public final class LuaRuntime {
    public struct Action: Equatable, Sendable {
        public let name: String
        public let title: String
    }

    public struct Binding: Equatable, Sendable {
        public let chord: String
        public let action: String
    }

    /// The `zetty.<verb>` functions forwarded to the host.
    public static let verbs = ["split", "send", "new_tab", "focus", "close", "notify", "status"]

    public private(set) var actions: [Action] = []
    public private(set) var bindings: [Binding] = []
    /// Load errors from the last `load`, newest last.
    public private(set) var errors: [String] = []
    /// The directory `init.lua` was loaded from, if any.
    public private(set) var configDirectory: String?
    /// Seconds one call into Lua may run before it is stopped, so a runaway
    /// loop in init.lua cannot freeze the app.
    public var budget: TimeInterval = 2
    /// Bytes the state may hold before a running call is stopped.
    public var memoryLimit: Int = 64 * 1_048_576 {
        didSet { memory?.pointee.limit = memoryLimit }
    }

    private weak var host: LuaHost?
    private let scheduler: LuaScheduler
    private let commandRunner: LuaCommandRunner
    /// What every `zetty.exec` command starts from; its `env` is merged over it.
    private let baseEnvironment: [String: String]
    private var state: OpaquePointer?
    /// The current state's timers and running commands, by the id Lua knows
    /// them by.
    private var timers: [Int: LuaCancellable] = [:]
    private var commands: [Int: LuaCancellable] = [:]
    private var nextID = 1

    /// Seconds a `zetty.exec` command may run when `opts.timeout` is not given.
    public static let defaultExecTimeout: TimeInterval = 30
    /// The current state's allocation counter (the allocator's `ud`).
    private var memory: UnsafeMutablePointer<LuaMemory>?
    /// Registry reference to the table the prelude returned.
    private var internalsRef: Int32 = LUA_NOREF

    public init(host: LuaHost, scheduler: LuaScheduler = MainQueueScheduler(),
                commands: LuaCommandRunner = ProcessCommandRunner(),
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.host = host
        self.scheduler = scheduler
        self.commandRunner = commands
        self.baseEnvironment = baseEnvironment
    }

    deinit {
        closeState()
    }

    // MARK: - Loading

    /// Loads `fileURL` into a fresh state. A file that does not compile keeps
    /// the previous state (and its actions) and records the error; a runtime
    /// error keeps what ran before it. A missing file leaves an empty state.
    public func load(fileURL: URL?) {
        errors = []
        let directory = fileURL?.deletingLastPathComponent().path
        guard let fresh = makeState(configDirectory: directory) else { return }
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            replaceState(with: fresh, configDirectory: directory)
            return
        }
        if luaL_loadfilex(fresh.L, fileURL.path, nil) != LUA_OK {
            errors.append(Self.string(fresh.L, at: -1))
            fresh.close()
            return
        }
        // The chunk sits on the new state's stack; run it once that state is current.
        replaceState(with: fresh, configDirectory: directory)
        if let message = protectedCall(arguments: 0, results: 0) {
            errors.append(message)
        }
        readManifest()
    }

    /// Stops everything and closes the state. Used when scripting is turned
    /// off and at quit.
    public func shutdown() {
        closeState()
        actions = []
        bindings = []
        errors = []
    }

    private struct PreparedState {
        let L: OpaquePointer
        let memory: UnsafeMutablePointer<LuaMemory>
        let internalsRef: Int32

        func close() {
            lua_close(L)
            memory.deallocate()
        }
    }

    private func replaceState(with fresh: PreparedState, configDirectory: String?) {
        closeState()
        state = fresh.L
        memory = fresh.memory
        internalsRef = fresh.internalsRef
        self.configDirectory = configDirectory
        actions = []
        bindings = []
    }

    private func closeState() {
        for handle in Array(timers.values) + Array(commands.values) { handle.cancel() }
        timers = [:]
        commands = [:]
        if let state { lua_close(state) }
        memory?.deallocate()
        state = nil
        memory = nil
        internalsRef = LUA_NOREF
    }

    private func makeState(configDirectory: String?) -> PreparedState? {
        guard let L = luaL_newstate() else {
            errors.append("could not start Lua")
            return nil
        }
        // Counting allocator, installed before the libraries allocate. Blocks
        // the default allocator already made are realloc/free blocks too, so
        // they stay compatible; freeing one may dip `used` below zero.
        let memory = UnsafeMutablePointer<LuaMemory>.allocate(capacity: 1)
        memory.initialize(to: LuaMemory(used: 0, limit: memoryLimit))
        lua_setallocf(L, countingAllocator, memory)
        luaL_openlibs(L)
        lua_sethook(L, budgetHook, LUA_MASKCOUNT, hookInterval)

        func fail(_ message: String) -> PreparedState? {
            errors.append("prelude: " + message)
            lua_close(L)
            memory.deallocate()
            return nil
        }
        guard luaL_loadbufferx(L, Self.prelude, Self.prelude.utf8.count, "=zetty", nil) == LUA_OK else {
            return fail(Self.string(L, at: -1))
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        lua_pushlightuserdata(L, me)
        lua_pushcclosure(L, rawEntry, 1)
        lua_pushlightuserdata(L, me)
        lua_pushcclosure(L, logEntry, 1)
        Self.push(L, configDirectory.map(LuaValue.string) ?? .null)
        memory.pointee.deadline = CFAbsoluteTimeGetCurrent() + budget
        let status = lua_pcallk(L, 3, 1, 0, 0, nil)
        memory.pointee.deadline = .infinity
        guard status == LUA_OK else { return fail(Self.string(L, at: -1)) }
        let ref = luaL_ref(L, LUA_REGISTRYINDEX)
        return PreparedState(L: L, memory: memory, internalsRef: ref)
    }

    /// Pushes `internals[name]`. Leaves the internals table under it; callers
    /// restore the stack top themselves.
    private func pushInternal(_ L: OpaquePointer, _ name: String) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, lua_Integer(internalsRef))
        lua_getfield(L, -1, name)
    }

    private func readManifest() {
        guard let L = state else { return }
        let top = lua_gettop(L)
        defer { lua_settop(L, top) }
        pushInternal(L, "manifest")
        guard protectedCall(arguments: 0, results: 1) == nil else { return }
        let manifest = Self.value(L, at: -1)
        actions = (manifest["actions"]?.array ?? []).compactMap { entry in
            guard let name = entry["name"]?.string else { return nil }
            return Action(name: name, title: entry["title"]?.string ?? name)
        }
        bindings = (manifest["binds"]?.array ?? []).compactMap { entry in
            guard let chord = entry["chord"]?.string, let action = entry["action"]?.string else { return nil }
            return Binding(chord: chord, action: action)
        }
    }

    // MARK: - Calling in

    /// Runs the action `name` with `context` as its `ctx`. Returns the error,
    /// or nil when it ran.
    @discardableResult
    public func runAction(_ name: String, context: LuaValue) -> String? {
        guard let L = state else { return "Lua is not loaded" }
        let top = lua_gettop(L)
        defer { lua_settop(L, top) }
        pushInternal(L, "run")
        Self.push(L, .string(name))
        Self.push(L, context)
        return protectedCall(arguments: 2, results: 0)
    }

    /// Calls every `zetty.on(event, fn)` handler. Each handler's error is
    /// reported to the host; one handler's failure does not stop the rest.
    public func emit(_ event: String, payload: LuaValue) {
        guard let L = state else { return }
        let top = lua_gettop(L)
        defer { lua_settop(L, top) }
        pushInternal(L, "emit")
        Self.push(L, .string(event))
        Self.push(L, payload)
        if let message = protectedCall(arguments: 2, results: 1) {
            host?.luaReportError("zetty.on('\(event)'): \(message)")
            return
        }
        for failure in Self.value(L, at: -1).array ?? [] {
            host?.luaReportError(failure.string ?? "zetty.on('\(event)'): error")
        }
    }

    /// Evaluates `code` in the live state, as an expression when it parses as
    /// one. Returns the results rendered with `zetty.inspect`, tab-separated.
    /// Running arbitrary code is the point: it is the user's own Lua, reached
    /// only through the same-user (0600) control socket, with the same powers
    /// init.lua already has.
    public func eval(_ code: String) -> Result<String, LuaHostError> {
        guard let L = state else { return .failure(LuaHostError("Lua is not loaded")) }
        let top = lua_gettop(L)
        defer { lua_settop(L, top) }
        let expression = "return " + code
        if luaL_loadbufferx(L, expression, expression.utf8.count, "=eval", nil) != LUA_OK {
            lua_settop(L, top)
            guard luaL_loadbufferx(L, code, code.utf8.count, "=eval", nil) == LUA_OK else {
                return .failure(LuaHostError(Self.string(L, at: -1)))
            }
        }
        if let message = protectedCall(arguments: 0, results: LUA_MULTRET) {
            return .failure(LuaHostError(message))
        }
        let count = lua_gettop(L) - top
        guard count > 0 else { return .success("") }
        var rendered: [String] = []
        for index in (top + 1)...(top + count) {
            pushInternal(L, "render")
            lua_pushvalue(L, index)
            if protectedCall(arguments: 1, results: 1) == nil {
                rendered.append(Self.string(L, at: -1))
            }
            lua_settop(L, top + count)
        }
        return .success(rendered.joined(separator: "\t"))
    }

    /// `lua_pcall` under the time budget. Pops the error and returns it.
    private func protectedCall(arguments: Int32, results: Int32) -> String? {
        guard let L = state, let memory else { return "Lua is not loaded" }
        // Nested calls (an action calling back in) keep the outer deadline.
        let previous = memory.pointee.deadline
        if previous == .infinity { memory.pointee.deadline = CFAbsoluteTimeGetCurrent() + budget }
        let status = lua_pcallk(L, arguments, results, 0, 0, nil)
        memory.pointee.deadline = previous
        // Collect whenever the cap was crossed, not only when the error says
        // so: a handler, timer or exec callback runs under its own pcall in
        // Lua, which swallows the memory error and returns normally.
        if memory.pointee.used > memory.pointee.limit { collectGarbage(L) }
        guard status == LUA_OK else {
            let message = Self.string(L, at: -1)
            lua_settop(L, -2)
            return message
        }
        return nil
    }

    /// A full collection after a call crossed the memory cap, so what it built
    /// and dropped does not keep tripping it.
    private func collectGarbage(_ L: OpaquePointer) {
        let top = lua_gettop(L)
        defer { lua_settop(L, top) }
        pushInternal(L, "gc")
        Self.push(L, .string("collect"))
        _ = lua_pcallk(L, 1, 0, 0, 0, nil)
    }

    // MARK: - Timers

    private func startTimer(_ argument: LuaValue) throws -> LuaValue {
        guard case .number(let seconds)? = argument["seconds"] else { throw LuaHostError("expects seconds") }
        let repeats = argument["repeats"]?.bool ?? false
        let id = nextID
        nextID += 1
        let owner = state
        timers[id] = scheduler.schedule(after: seconds, repeats: repeats) { [weak self] in
            self?.fireTimer(id, repeats: repeats, owner: owner)
        }
        return .number(Double(id))
    }

    /// Runs timer `id`'s callback, unless the state it belonged to is gone.
    private func fireTimer(_ id: Int, repeats: Bool, owner: OpaquePointer?) {
        guard let L = state, L == owner, timers[id] != nil else { return }
        if !repeats { timers[id] = nil }
        let top = lua_gettop(L)
        defer { lua_settop(L, top) }
        pushInternal(L, "fire")
        Self.push(L, .number(Double(id)))
        if let message = protectedCall(arguments: 1, results: 1) {
            host?.luaReportError("timer: \(message)")
        } else if lua_type(L, -1) == LUA_TSTRING {
            host?.luaReportError("timer: \(Self.string(L, at: -1))")
        }
    }

    // MARK: - Commands

    /// `argument` is `{ cmd, cwd?, timeout?, env? }`, already checked in Lua.
    private func startCommand(_ argument: LuaValue) throws -> LuaValue {
        let program: LuaCommand.Program
        switch argument["cmd"] {
        case .string(let script)?:
            program = .shell(script)
        case .array(let parts)? where !parts.isEmpty && parts.allSatisfy({ $0.string != nil }):
            program = .argv(parts.compactMap(\.string))
        default:
            throw LuaHostError("expects a command string or an array of strings")
        }
        let cwd = argument["cwd"]?.string.map { ($0 as NSString).expandingTildeInPath }
            ?? configDirectory ?? NSHomeDirectory()
        var timeout = Self.defaultExecTimeout
        if case .number(let seconds)? = argument["timeout"] { timeout = seconds }
        var environment = baseEnvironment
        if case .table(let extra)? = argument["env"] {
            for (key, value) in extra { if let text = value.string { environment[key] = text } }
        }
        let id = nextID
        nextID += 1
        let owner = state
        let command = LuaCommand(program: program, cwd: cwd, timeout: timeout, environment: environment)
        commands[id] = commandRunner.run(command) { [weak self] result in
            self?.finishCommand(id, result: result, owner: owner)
        }
        return .number(Double(id))
    }

    /// Hands a finished command's result to its callback, unless the state
    /// it belonged to is gone or it was cancelled.
    private func finishCommand(_ id: Int, result: LuaCommandResult, owner: OpaquePointer?) {
        guard let L = state, L == owner, commands.removeValue(forKey: id) != nil else { return }
        let top = lua_gettop(L)
        defer { lua_settop(L, top) }
        pushInternal(L, "exec_done")
        Self.push(L, .number(Double(id)))
        Self.push(L, .table([
            "code": .number(Double(result.code)),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "timed_out": .bool(result.timedOut),
        ]))
        if let message = protectedCall(arguments: 2, results: 1) {
            host?.luaReportError("zetty.exec: \(message)")
        } else if lua_type(L, -1) == LUA_TSTRING {
            host?.luaReportError("zetty.exec: \(Self.string(L, at: -1))")
        }
    }

    // MARK: - Entry points from Lua

    /// Verbs starting with `_` belong to the runtime itself and never reach
    /// the host.
    private func handleInternal(_ verb: String, _ argument: LuaValue) throws -> LuaValue {
        switch verb {
        case "_after":
            return try startTimer(argument)
        case "_cancel":
            if case .number(let id) = argument { timers.removeValue(forKey: Int(id))?.cancel() }
            return .bool(true)
        case "_exec":
            return try startCommand(argument)
        case "_cancel_exec":
            if case .number(let id) = argument { commands.removeValue(forKey: Int(id))?.cancel() }
            return .bool(true)
        default:
            throw LuaHostError("unknown verb '\(verb)'")
        }
    }

    fileprivate func handleRaw(_ L: OpaquePointer) -> Int32 {
        let verb = Self.string(L, at: 1)
        let argument = Self.value(L, at: 2)
        if verb.hasPrefix("_") {
            do {
                Self.push(L, try handleInternal(verb, argument))
                return 1
            } catch {
                Self.push(L, .null)
                Self.push(L, .string((error as? LuaHostError)?.message ?? String(describing: error)))
                return 2
            }
        }
        guard let host else {
            Self.push(L, .null)
            Self.push(L, .string("Zetty is shutting down"))
            return 2
        }
        do {
            Self.push(L, try host.luaCall(verb, argument))
            return 1
        } catch let error as LuaHostError {
            Self.push(L, .null)
            Self.push(L, .string(error.message))
            return 2
        } catch {
            Self.push(L, .null)
            Self.push(L, .string(String(describing: error)))
            return 2
        }
    }

    fileprivate func handleLog(_ L: OpaquePointer) -> Int32 {
        host?.luaLog(Self.string(L, at: 1))
        return 0
    }
}

// MARK: - C entry points

/// What every thread of one state shares, reached through the allocator's
/// `ud` (`lua_getallocf`): the bytes it holds and its cap, and the deadline of
/// the running call. Not `LUA_EXTRASPACE`: `lua_newthread` copies that once,
/// so a coroutine resumed in a later call would see the deadline of the call
/// that created it. `used` is signed: blocks allocated before the counting
/// allocator was installed are freed through it too.
struct LuaMemory {
    var used: Int
    var limit: Int
    var deadline: CFAbsoluteTime = .infinity
}

/// Instructions between budget checks while a call is within its limits.
private let hookInterval: Int32 = 10_000

/// realloc/free that counts. Never returns NULL for a size the system can
/// give: a failed allocation raises a Lua error from whichever frame
/// allocated, Swift frames that push values included.
private let countingAllocator: lua_Alloc = { ud, block, oldSize, newSize in
    let memory = ud!.assumingMemoryBound(to: LuaMemory.self)
    if newSize == 0 {
        if block != nil { memory.pointee.used -= oldSize }
        free(block)
        return nil
    }
    guard let grown = realloc(block, newSize) else { return nil }
    // For a new block, `oldSize` names the object type, not a size.
    memory.pointee.used += newSize - (block == nil ? 0 : oldSize)
    return grown
}

/// Count hook: raises from inside the VM once the deadline passes or the
/// state holds more than its memory cap. Holds no Swift references, since
/// `lua_error` longjmps out of this frame.
///
/// Once tripped, it checks on every instruction of that thread: otherwise a
/// `pcall` retry loop catches the error, runs a few instructions, and calls
/// back in, so every 10,000th instruction lands inside the protected call
/// again and the loop never ends. Within limits again (the next call), it
/// drops back to the normal interval.
private let budgetHook: lua_Hook = { L, _ in
    guard let L else { return }
    var ud: UnsafeMutableRawPointer?
    _ = lua_getallocf(L, &ud)
    guard let shared = ud?.assumingMemoryBound(to: LuaMemory.self).pointee else { return }
    let overMemory = shared.used > shared.limit
    let overTime = CFAbsoluteTimeGetCurrent() > shared.deadline
    guard overMemory || overTime else {
        if lua_gethookcount(L) != hookInterval { lua_sethook(L, budgetHook, LUA_MASKCOUNT, hookInterval) }
        return
    }
    if lua_gethookcount(L) != 1 { lua_sethook(L, budgetHook, LUA_MASKCOUNT, 1) }
    lua_pushstring(L, overMemory ? "script used more than its memory limit"
                                 : "script ran past its time budget and was stopped")
    lua_error(L)
}

/// LUA_REGISTRYINDEX - 1: the first upvalue (a macro Swift cannot import).
private let firstUpvalue: Int32 = -1_000_000 - 1000 - 1
/// LUA_REGISTRYINDEX (a macro Swift cannot import).
let LUA_REGISTRYINDEX: Int32 = -1_000_000 - 1000

private let rawEntry: lua_CFunction = { L in
    guard let L, let me = lua_touserdata(L, firstUpvalue) else { return 0 }
    return Unmanaged<LuaRuntime>.fromOpaque(me).takeUnretainedValue().handleRaw(L)
}

private let logEntry: lua_CFunction = { L in
    guard let L, let me = lua_touserdata(L, firstUpvalue) else { return 0 }
    return Unmanaged<LuaRuntime>.fromOpaque(me).takeUnretainedValue().handleLog(L)
}
