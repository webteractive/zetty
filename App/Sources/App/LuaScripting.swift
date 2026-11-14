import AppKit
import UserNotifications
import ZettyCore
import ZettyLua

/// Where `zetty.close` reads its busy-pane answer from: the reading a socket
/// request took, or none (the cached probe).
protocol LuaForegroundGate: AnyObject {
    var cliForegroundReading: BusyPaneGate.Reading? { get set }
}

/// What Settings → Scripting and the status-bar chip show.
struct LuaScriptingState {
    var enabled: Bool
    var fileExists: Bool
    var loadedAt: Date?
    var actions: [(name: String, title: String, chord: String?)]
    /// Load errors, then handler, timer, exec and action errors since the
    /// last load, newest last.
    var errors: [String]
    /// The most recent `print` / `zetty.log` lines, newest last.
    var output: [String]
}

/// Runs `~/.config/zetty/init.lua`. Each `zetty.<verb>` goes through the
/// control socket's own request handler, so Lua can do what the `zetty` CLI
/// can, with the same checks. Main thread only.
final class LuaScripting: LuaHost {

    static var fileURL: URL {
        ConfigStore().fileURL.deletingLastPathComponent().appendingPathComponent("init.lua")
    }

    /// Key whose presence in a notification's userInfo lets it show while
    /// Zetty is active (`willPresent`).
    static let notificationKey = "lua"

    /// Posted (coalesced, on main) whenever `state` changes.
    static let didChangeNotification = Notification.Name("ZettyLuaScriptingDidChange")

    /// Lines kept in `state.output`, and errors kept in `state.errors`.
    static let ringSize = 50

    static let offMessage = "scripting is off (zetty-scripting = false)"

    /// Called after a reload the file watcher started, so the app can lay the
    /// new bindings over its key table.
    var onBindingsChanged: (() -> Void)?

    private let perform: (ControlRequest) -> ControlResponse
    private weak var foregroundGate: LuaForegroundGate?
    /// What runs in each preserved pane right now, read on the spot.
    private let freshForegroundReading: () -> BusyPaneGate.Reading?
    private lazy var runtime = LuaRuntime(host: self, baseEnvironment: Self.commandEnvironment())
    private var watcher: ConfigFileWatcher?

    private(set) var isEnabled = false
    private var loadedAt: Date?
    private var reportedErrors: [String] = []
    private var output: [String] = []
    private var changePosted = false
    /// > 0 while a `zetty.<verb>` is being carried out. Workspace changes made
    /// then are the script's own, and fire no pane events back into Lua.
    private var verbDepth = 0

    var isRunningLua: Bool { verbDepth > 0 }

    var actions: [LuaRuntime.Action] { isEnabled ? runtime.actions : [] }

    init(perform: @escaping (ControlRequest) -> ControlResponse, foregroundGate: LuaForegroundGate?,
         freshForegroundReading: @escaping () -> BusyPaneGate.Reading?) {
        self.perform = perform
        self.foregroundGate = foregroundGate
        self.freshForegroundReading = freshForegroundReading
    }

    /// Zetty's environment with the tool directories first on `PATH`, so
    /// Homebrew tools and `gh` are found from a GUI app.
    private static func commandEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let inherited = environment["PATH"].map { ":" + $0 } ?? ""
        environment["PATH"] = ToolSearchPath.directories().joined(separator: ":") + inherited
        return environment
    }

    // MARK: - Loading

    /// Loads init.lua again, or stops everything when `enabled` is false.
    /// Starts watching the file the first time it is called.
    func reload(enabled: Bool) {
        isEnabled = enabled
        reportedErrors = []
        if enabled {
            runtime.load(fileURL: Self.fileURL)
            loadedAt = FileManager.default.fileExists(atPath: Self.fileURL.path) ? Date() : nil
            for error in runtime.errors { ZettyLog.config.error("init.lua: \(error)") }
            // An error at load, not a key that silently does nothing.
            for binding in runtime.bindings where ScriptBinding.chord(binding.chord) == nil {
                recordError("zetty.bind: invalid chord \"\(binding.chord)\" (use \"prefix>d\" or \"d\")")
            }
            ZettyLog.config.log("init.lua: \(runtime.actions.count) action(s), \(runtime.bindings.count) binding(s)")
        } else {
            runtime.shutdown()
            loadedAt = nil
        }
        startWatching()
        stateChanged()
    }

    private func startWatching() {
        guard watcher == nil else { return }
        let watcher = ConfigFileWatcher(url: Self.fileURL) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.reload(enabled: true)
            self.onBindingsChanged?()
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Stops timers and commands at quit.
    func shutdown() {
        watcher?.stop()
        runtime.shutdown()
    }

    var state: LuaScriptingState {
        let chords = Dictionary(runtime.bindings.map { ($0.action, $0.chord) }, uniquingKeysWith: { first, _ in first })
        return LuaScriptingState(
            enabled: isEnabled,
            fileExists: FileManager.default.fileExists(atPath: Self.fileURL.path),
            loadedAt: loadedAt,
            actions: actions.map { (name: $0.name, title: $0.title, chord: chords[$0.name]) },
            errors: isEnabled ? Array((runtime.errors + reportedErrors).suffix(Self.ringSize)) : [],
            output: output)
    }

    /// The prefix chord bound to `action`, as written in init.lua.
    func chord(for action: String) -> String? {
        guard isEnabled else { return nil }
        return runtime.bindings.first { $0.action == action }?.chord
    }

    /// `config` with init.lua's `zetty.bind` lines laid over it. Prefix layer
    /// only: `"prefix>d"` or plain `"d"`.
    func applyingBindings(to config: KeyBindingConfiguration) -> KeyBindingConfiguration {
        guard isEnabled else { return config }
        var config = config
        // A chord that does not parse is reported at load (`reload`).
        for binding in runtime.bindings {
            guard let chord = ScriptBinding.chord(binding.chord) else { continue }
            config.prefixTable[chord] = .script(binding.action)
        }
        return config
    }

    // MARK: - Calling in

    /// Runs an action with the focused pane as `ctx`. `source` is `"key"`,
    /// `"palette"` or `"cli"`. Returns the error.
    @discardableResult
    func run(_ name: String, source: String) -> String? {
        guard isEnabled else { return Self.offMessage }
        guard runtime.actions.contains(where: { $0.name == name }) else {
            return "no action named '\(name)' in init.lua"
        }
        let error = runtime.runAction(name, context: context(source: source))
        if let error { recordError("action \(name): \(error)") }
        return error
    }

    func emit(_ event: String, _ payload: [String: LuaValue]) {
        guard isEnabled else { return }
        runtime.emit(event, payload: .table(payload))
    }

    func eval(_ code: String) -> ControlResponse {
        guard isEnabled else { return .error(Self.offMessage) }
        switch runtime.eval(code) {
        case .success(let text): return .text(text)
        case .failure(let error): return .error(error.message)
        }
    }

    private func context(source: String) -> LuaValue {
        var context: [String: LuaValue] = ["source": .string(source)]
        if case .status(let snapshot) = perform(.status),
           let pane = snapshot.panes.first(where: \.isFocused) {
            context["pane"] = .string(pane.id)
            if let cwd = pane.cwd { context["cwd"] = .string(cwd) }
            if let project = snapshot.projects.first(where: { $0.tabs.contains { $0.panes.contains { $0.id == pane.id } } }) {
                context["project"] = .string(project.name)
            }
        }
        return .table(context)
    }

    // MARK: - LuaHost

    func luaCall(_ verb: String, _ argument: LuaValue) throws -> LuaValue {
        verbDepth += 1
        defer { verbDepth -= 1 }
        switch verb {
        case "status":
            guard case .status(let snapshot) = perform(.status) else {
                throw LuaHostError("status is unavailable")
            }
            return try LuaValue(encoding: snapshot)
        case "split":
            let direction = argument["direction"]?.string ?? "right"
            guard direction == "right" || direction == "down" else {
                throw LuaHostError("direction must be \"right\" or \"down\"")
            }
            return try answer(perform(.split(target: target(argument), vertical: direction == "right",
                                             focus: argument["focus"]?.bool ?? false,
                                             account: argument["account"]?.string)))
        case "send":
            if let text = argument.string {
                return try answer(perform(.send(target: .focused, text: text, enter: false, keys: [])))
            }
            let keys = argument["keys"]?.array?.compactMap(\.string)
                ?? argument["key"]?.string.map { [$0] } ?? []
            return try answer(perform(.send(target: target(argument), text: argument["text"]?.string,
                                            enter: argument["enter"]?.bool ?? false, keys: keys)))
        case "new_tab":
            return try answer(perform(.newTab(project: argument["project"]?.string,
                                              focus: argument["focus"]?.bool ?? false,
                                              account: argument["account"]?.string)))
        case "focus":
            if let pane = argument.string { return try answer(perform(.focus(target: .pane(pane)))) }
            return try answer(perform(.focus(target: target(argument))))
        case "close":
            return try close(argument)
        case "notify":
            guard let body = argument.string ?? argument["text"]?.string else {
                throw LuaHostError("expects a string or { title, text }")
            }
            notify(title: argument["title"]?.string ?? "Zetty", body: body)
            return .bool(true)
        default:
            throw LuaHostError("unknown verb '\(verb)'")
        }
    }

    /// `zetty.close`, gated like the CLI's. The cached probe can't answer it:
    /// it polls every few seconds and stops while Zetty is in the background,
    /// so a pane that started `sleep 100` a moment ago reads as idle. Unless
    /// a socket request already took a reading (`zetty do`), an unforced
    /// close takes its own, briefly bounded; a timeout refuses the close.
    private func close(_ argument: LuaValue) throws -> LuaValue {
        let force = argument["force"]?.bool ?? false
        let previous = foregroundGate?.cliForegroundReading
        let readHere = !force && previous == nil
        if readHere { foregroundGate?.cliForegroundReading = freshForegroundReading() }
        defer { if readHere { foregroundGate?.cliForegroundReading = previous } }
        do {
            return try answer(perform(.close(target: target(argument),
                                             wholeTab: argument["tab"]?.bool ?? false,
                                             force: force)))
        } catch let error as LuaHostError {
            throw LuaHostError(error.message.replacingOccurrences(of: "--force", with: "force = true"))
        }
    }

    func luaLog(_ message: String) {
        ZettyLog.config.log("lua: \(message)")
        output.append(message)
        if output.count > Self.ringSize { output.removeFirst(output.count - Self.ringSize) }
        stateChanged()
    }

    func luaReportError(_ message: String) {
        recordError(message)
    }

    private func recordError(_ message: String) {
        ZettyLog.config.error("init.lua: \(message)")
        reportedErrors.append(message)
        if reportedErrors.count > Self.ringSize { reportedErrors.removeFirst(reportedErrors.count - Self.ringSize) }
        stateChanged()
    }

    /// One notification per run-loop turn, however many lines a script prints.
    private func stateChanged() {
        guard !changePosted else { return }
        changePosted = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changePosted = false
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    private func target(_ argument: LuaValue) -> PaneSelector {
        if let pane = argument["pane"]?.string { return .pane(pane) }
        if let cwd = argument["cwd"]?.string { return .cwd((cwd as NSString).expandingTildeInPath) }
        return .focused
    }

    private func answer(_ response: ControlResponse) throws -> LuaValue {
        switch response {
        case .ok: return .bool(true)
        case .pane(let id): return .string(id)
        case .text(let text): return .string(text)
        case .error(let message): throw LuaHostError(message)
        default: return .null
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [Self.notificationKey: true]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// `zetty.close` from Lua reads and sets the same per-request reading a
/// socket `close` does.
extension TerminalViewController: LuaForegroundGate {}
