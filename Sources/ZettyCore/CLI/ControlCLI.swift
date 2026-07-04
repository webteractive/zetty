import Foundation

/// The `zetty` CLI: argument parsing, socket round-trip, output.
///
/// Lives in ZettyCore so both the standalone `Zetty` executable and the
/// app binary itself (invoked as `zetty <command>` via the installed
/// symlink) share one implementation. Returns a process exit code:
/// 0 success · 1 error (message on stderr) · 2 usage.
public enum ControlCLI {

    public static let usage = """
    usage:
      zetty status [--json]                 workspace tree: projects → tabs → panes
      zetty send [options] [text …]         inject input into a pane's terminal
        --pane <id>       target a pane by (unique prefix of) its 8-hex id
        --cwd <path>      target the single pane whose working dir is <path>
        --key <name>      append a key (Enter, Escape, Tab, BTab, Up, Down, Left,
                          Right, Home, End, PageUp, PageDown, Delete, BSpace,
                          Space, C-a … C-z); repeatable, applied in order
        --enter, -e       append a carriage return after text/keys
      zetty capture [--pane <id> | --cwd <path>] [--lines <n>]
                                              print a pane's recent output (via its
                                              preserved zmx session)
      zetty new-tab [--project <name>]      open a tab (active project by default);
                                              prints the new pane's id on stdout
      zetty add-project <path> [--name <name>]
                                              add a directory as a project (made
                                              active, one fresh tab); prints its
                                              first pane's id on stdout
      zetty remove-project <name>           remove a project (closes its tabs and
                                              ends their sessions; no confirmation;
                                              the last project can't be removed)
      zetty split [--pane <id> | --cwd <path>] [--horizontal]
                                              split a pane (vertical by default);
                                              prints the new pane's id on stdout
      zetty break [--pane <id> | --cwd <path>]
                                              break a pane into a new adjacent tab;
                                              prints the moved pane's id on stdout
      zetty focus (--pane <id> | --cwd <path>)
                                              focus a pane (selects its project/tab)
      zetty close (--pane <id> | --cwd <path>) [--tab]
                                              close a pane (a tab's last pane closes
                                              the tab; --tab closes the whole tab)
      zetty reload                          reload zetty config (⇧⌘, equivalent)
      zetty quit [--kill-sessions]          quit the app (no confirmation dialog);
                                              --kill-sessions also kills every
                                              preserved zmx session (full shutdown)

    Notes (script/agent friendly):
      - The default send/capture/split target is the focused pane. Send text
        arguments are joined with spaces and sent verbatim; keys append after.
      - `status --json` prints the full machine-readable tree (pane ids, titles,
        cwd, running tool, agent status, focus). `new-tab`/`split` print just
        the pane id, so: zetty send --pane "$(zetty new-tab)" ls --enter
      - Give a fresh pane ~1–2s for its shell to start before sending input.
      - new-tab/split/add-project select the new pane (it must be visible for
        its shell to spawn); close/send/capture leave the visible view alone.
      - Exit codes: 0 success · 1 error (message on stderr) · 2 usage.
      - Requires the zetty app to be running (socket: ~/.zetty/zetty.sock).
    """

    /// True when `arguments` look like a CLI invocation (used by the app
    /// binary to decide CLI mode vs. launching the GUI).
    public static func recognizes(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return ["status", "ls", "send", "capture", "new-tab", "add-project", "remove-project",
                "split", "break", "focus", "close", "reload", "quit",
                "help", "--help", "-h"].contains(first)
    }

    public static func run(_ arguments: [String]) -> Int32 {
        var arguments = arguments
        guard let command = arguments.first else {
            print(usage)
            return 2
        }
        arguments.removeFirst()

        switch command {
        case "help", "--help", "-h":
            print(usage)
            return 0
        case "status", "ls":
            return runStatus(arguments)
        case "send":
            return runSend(arguments)
        case "capture":
            return runCapture(arguments)
        case "new-tab":
            return runNewTab(arguments)
        case "add-project":
            return runAddProject(arguments)
        case "remove-project":
            return runRemoveProject(arguments)
        case "split":
            return runSplit(arguments)
        case "break":
            return runBreak(arguments)
        case "focus":
            return runFocus(arguments)
        case "close":
            return runClose(arguments)
        case "reload":
            return expectOK(.reload, success: "reloaded")
        case "quit":
            return expectOK(.quit(killSessions: arguments.contains("--kill-sessions")), success: nil)
        default:
            return failure("unknown command \"\(command)\"\n\n\(usage)")
        }
    }

    // MARK: - Commands

    private static func runStatus(_ arguments: [String]) -> Int32 {
        switch roundTrip(.status) {
        case .status(let snapshot):
            printStatus(snapshot, json: arguments.contains("--json"))
            return 0
        case .error(let message): return failure(message)
        default: return failure("unexpected response")
        }
    }

    private static func runSend(_ arguments: [String]) -> Int32 {
        var target = PaneSelector.focused
        var keys: [String] = []
        var enter = false
        var textParts: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane":
                index += 1
                guard index < arguments.count else { return failure("--pane needs a value") }
                target = .pane(arguments[index])
            case "--cwd":
                index += 1
                guard index < arguments.count else { return failure("--cwd needs a value") }
                target = .cwd(arguments[index])
            case "--key":
                index += 1
                guard index < arguments.count else { return failure("--key needs a value") }
                guard KeyNotation.encode(arguments[index]) != nil else {
                    return failure("unknown key \"\(arguments[index])\"")
                }
                keys.append(arguments[index])
            case "--enter", "-e":
                enter = true
            case "--help", "-h":
                print(usage)
                return 0
            default:
                textParts.append(arguments[index])
            }
            index += 1
        }
        let text = textParts.isEmpty ? nil : textParts.joined(separator: " ")
        guard text != nil || !keys.isEmpty || enter else {
            return failure("nothing to send — pass text, --key, or --enter")
        }
        return expectOK(.send(target: target, text: text, enter: enter, keys: keys), success: nil)
    }

    private static func runCapture(_ arguments: [String]) -> Int32 {
        var target = PaneSelector.focused
        var lines: Int?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane":
                index += 1
                guard index < arguments.count else { return failure("--pane needs a value") }
                target = .pane(arguments[index])
            case "--cwd":
                index += 1
                guard index < arguments.count else { return failure("--cwd needs a value") }
                target = .cwd(arguments[index])
            case "--lines":
                index += 1
                guard index < arguments.count, let count = Int(arguments[index]), count > 0 else {
                    return failure("--lines needs a positive number")
                }
                lines = count
            case "--help", "-h":
                print(usage)
                return 0
            default:
                return failure("unknown argument \"\(arguments[index])\"")
            }
            index += 1
        }
        switch roundTrip(.capture(target: target, lines: lines)) {
        case .text(let text):
            print(text)
            return 0
        case .error(let message): return failure(message)
        default: return failure("unexpected response")
        }
    }

    private static func runNewTab(_ arguments: [String]) -> Int32 {
        var project: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--project":
                index += 1
                guard index < arguments.count else { return failure("--project needs a value") }
                project = arguments[index]
            case "--help", "-h":
                print(usage)
                return 0
            default:
                return failure("unknown argument \"\(arguments[index])\"")
            }
            index += 1
        }
        return expectPane(.newTab(project: project))
    }

    private static func runAddProject(_ arguments: [String]) -> Int32 {
        var name: String?
        var pathParts: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--name":
                index += 1
                guard index < arguments.count else { return failure("--name needs a value") }
                name = arguments[index]
            case "--help", "-h":
                print(usage)
                return 0
            default:
                pathParts.append(arguments[index])
            }
            index += 1
        }
        // Positional path — joined so unquoted paths with spaces still work.
        let raw = pathParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            return failure("add-project needs a directory path")
        }
        // Resolve here: relative paths are relative to the CLI's cwd, not the app's.
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return expectPane(.addProject(path: absolute, name: name))
    }

    private static func runRemoveProject(_ arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        // Positional name — joined so unquoted multi-word names still work.
        let name = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return failure("remove-project needs a project name")
        }
        return expectOK(.removeProject(name: name), success: nil)
    }

    private static func runSplit(_ arguments: [String]) -> Int32 {
        var target = PaneSelector.focused
        var vertical = true
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane":
                index += 1
                guard index < arguments.count else { return failure("--pane needs a value") }
                target = .pane(arguments[index])
            case "--cwd":
                index += 1
                guard index < arguments.count else { return failure("--cwd needs a value") }
                target = .cwd(arguments[index])
            case "--horizontal":
                vertical = false
            case "--vertical":
                vertical = true
            case "--help", "-h":
                print(usage)
                return 0
            default:
                return failure("unknown argument \"\(arguments[index])\"")
            }
            index += 1
        }
        return expectPane(.split(target: target, vertical: vertical))
    }

    private static func runBreak(_ arguments: [String]) -> Int32 {
        var target = PaneSelector.focused
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane":
                index += 1
                guard index < arguments.count else { return failure("--pane needs a value") }
                target = .pane(arguments[index])
            case "--cwd":
                index += 1
                guard index < arguments.count else { return failure("--cwd needs a value") }
                target = .cwd(arguments[index])
            case "--help", "-h":
                print(usage)
                return 0
            default:
                return failure("unknown argument \"\(arguments[index])\"")
            }
            index += 1
        }
        return expectPane(.breakPane(target: target))
    }

    private static func runFocus(_ arguments: [String]) -> Int32 {
        guard let target = parseRequiredTarget(arguments) else {
            return failure("focus needs an explicit target: --pane <id> or --cwd <path>")
        }
        return expectOK(.focus(target: target), success: nil)
    }

    private static func runClose(_ arguments: [String]) -> Int32 {
        var target: PaneSelector?
        var wholeTab = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane":
                index += 1
                guard index < arguments.count else { return failure("--pane needs a value") }
                target = .pane(arguments[index])
            case "--cwd":
                index += 1
                guard index < arguments.count else { return failure("--cwd needs a value") }
                target = .cwd(arguments[index])
            case "--tab":
                wholeTab = true
            case "--help", "-h":
                print(usage)
                return 0
            default:
                return failure("unknown argument \"\(arguments[index])\"")
            }
            index += 1
        }
        guard let target else {
            return failure("close needs an explicit target: --pane <id> or --cwd <path>")
        }
        return expectOK(.close(target: target, wholeTab: wholeTab), success: nil)
    }

    private static func parseRequiredTarget(_ arguments: [String]) -> PaneSelector? {
        var target: PaneSelector?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane":
                index += 1
                guard index < arguments.count else { return nil }
                target = .pane(arguments[index])
            case "--cwd":
                index += 1
                guard index < arguments.count else { return nil }
                target = .cwd(arguments[index])
            default:
                return nil
            }
            index += 1
        }
        return target
    }

    // MARK: - Round-trip + output helpers

    private static func expectOK(_ request: ControlRequest, success: String?) -> Int32 {
        switch roundTrip(request) {
        case .ok:
            if let success { print(success) }
            return 0
        case .error(let message): return failure(message)
        default: return failure("unexpected response")
        }
    }

    private static func expectPane(_ request: ControlRequest) -> Int32 {
        switch roundTrip(request) {
        case .pane(let id):
            print(id)
            return 0
        case .error(let message): return failure(message)
        default: return failure("unexpected response")
        }
    }

    private static func failure(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("Zetty: \(message)\n".utf8))
        return 1
    }

    /// One request → one response over the app's Unix socket.
    private static func roundTrip(_ request: ControlRequest) -> ControlResponse {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".zetty/zetty.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .error("cannot create socket") }
        defer { close(fd) }

        // Don't die by SIGPIPE if the app closes mid-exchange, and don't hang
        // a script forever if the app is wedged — fail with an error instead.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return .error("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(start: source.baseAddress, count: source.count))
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            return .error("cannot reach zetty at \(path) — is the app running?")
        }

        guard let out = try? ControlWire.encodeLine(request) else { return .error("cannot encode request") }
        let outBytes = Array(out.utf8)
        _ = outBytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.contains(0x0A) { break }
        }
        guard !buffer.isEmpty else {
            return .error("no response from zetty (timed out or connection closed)")
        }
        guard let line = String(data: buffer, encoding: .utf8),
              let response = try? ControlWire.decodeResponse(line) else {
            return .error("malformed response from app")
        }
        return response
    }

    private static func printStatus(_ snapshot: StatusSnapshot, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                print(String(data: data, encoding: .utf8) ?? "{}")
            }
            return
        }
        for project in snapshot.projects {
            print("\(project.isActive ? "●" : "○") \(project.name)")
            for tab in project.tabs {
                print("  \(tab.isActive ? "▸" : " ") \(tab.title)")
                for pane in tab.panes {
                    var fields = [pane.id]
                    if let tool = pane.tool { fields.append("[\(tool)]") }
                    if let status = pane.agentStatus { fields.append("(\(status))") }
                    if let title = pane.title, !title.isEmpty { fields.append(title) }
                    if let cwd = pane.cwd { fields.append("— \(cwd)") }
                    if pane.isFocused { fields.append("*") }
                    print("      \(fields.joined(separator: "  "))")
                }
            }
        }
    }
}
