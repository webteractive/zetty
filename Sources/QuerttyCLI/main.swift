import Foundation
import QuerttyCore

/// `quertty` — control CLI for the quertty app.
///
/// Talks line-JSON (`ControlWire`) to the app's Unix socket at
/// `~/.quertty/quertty.sock`. See `usage` below for the command grammar.

let usage = """
usage:
  quertty status [--json]                 workspace tree: projects → tabs → panes
  quertty send [options] [text …]         inject input into a pane's terminal
    --pane <id>       target a pane by (unique prefix of) its 8-hex id
    --cwd <path>      target the single pane whose working dir is <path>
    --key <name>      append a key (Enter, Escape, Tab, BTab, Up, Down, Left,
                      Right, Home, End, PageUp, PageDown, Delete, BSpace,
                      Space, C-a … C-z); repeatable, applied in order
    --enter, -e       append a carriage return after text/keys
  quertty new-tab [--project <name>]      open a tab (active project by default);
                                          prints the new pane's id on stdout
  quertty close (--pane <id> | --cwd <path>) [--tab]
                                          close a pane (a tab's last pane closes
                                          the tab; --tab closes the whole tab)
  quertty reload                          reload quertty config (⇧⌘, equivalent)
  quertty quit [--kill-sessions]          quit the app (no confirmation dialog);
                                          --kill-sessions also kills every
                                          preserved zmx session (full shutdown)

Notes (script/agent friendly):
  - The default send target is the focused pane. Text arguments are joined
    with spaces and sent verbatim; keys are appended after the text.
  - `status --json` prints the full machine-readable tree (pane ids, titles,
    cwd, running tool, agent status, focus). Plain `new-tab` output is just
    the pane id, so: quertty send --pane "$(quertty new-tab)" ls --enter
  - Give a fresh pane ~1–2s for its shell to start before sending input.
  - Exit codes: 0 success · 1 error (message on stderr) · 2 usage.
  - Requires the quertty app to be running (socket: ~/.quertty/quertty.sock).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("quertty: \(message)\n".utf8))
    exit(1)
}

// MARK: - Socket round-trip

func roundTrip(_ request: ControlRequest) -> ControlResponse {
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".quertty/quertty.sock")
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("cannot create socket") }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { fail("socket path too long") }
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
        fail("cannot reach quertty at \(path) — is the app running?")
    }

    guard let out = try? ControlWire.encodeLine(request) else { fail("cannot encode request") }
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
    guard let line = String(data: buffer, encoding: .utf8),
          let response = try? ControlWire.decodeResponse(line) else {
        fail("malformed response from app")
    }
    return response
}

// MARK: - Output

func printStatus(_ snapshot: StatusSnapshot, json: Bool) {
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

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(2)
}
arguments.removeFirst()

switch command {
case "status", "ls":
    let json = arguments.contains("--json")
    switch roundTrip(.status) {
    case .status(let snapshot): printStatus(snapshot, json: json)
    case .error(let message): fail(message)
    default: fail("unexpected response")
    }

case "send":
    var target = PaneSelector.focused
    var keys: [String] = []
    var enter = false
    var textParts: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--pane":
            index += 1
            guard index < arguments.count else { fail("--pane needs a value") }
            target = .pane(arguments[index])
        case "--cwd":
            index += 1
            guard index < arguments.count else { fail("--cwd needs a value") }
            target = .cwd(arguments[index])
        case "--key":
            index += 1
            guard index < arguments.count else { fail("--key needs a value") }
            guard KeyNotation.encode(arguments[index]) != nil else { fail("unknown key \"\(arguments[index])\"") }
            keys.append(arguments[index])
        case "--enter", "-e":
            enter = true
        case "--help", "-h":
            print(usage)
            exit(0)
        default:
            textParts.append(argument)
        }
        index += 1
    }
    let text = textParts.isEmpty ? nil : textParts.joined(separator: " ")
    guard text != nil || !keys.isEmpty || enter else { fail("nothing to send — pass text, --key, or --enter") }
    switch roundTrip(.send(target: target, text: text, enter: enter, keys: keys)) {
    case .ok: break
    case .error(let message): fail(message)
    default: fail("unexpected response")
    }

case "new-tab":
    var project: String?
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--project":
            index += 1
            guard index < arguments.count else { fail("--project needs a value") }
            project = arguments[index]
        case "--help", "-h":
            print(usage)
            exit(0)
        default:
            fail("unknown argument \"\(arguments[index])\"")
        }
        index += 1
    }
    switch roundTrip(.newTab(project: project)) {
    case .pane(let id): print(id)
    case .error(let message): fail(message)
    default: fail("unexpected response")
    }

case "close":
    var target: PaneSelector?
    var wholeTab = false
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--pane":
            index += 1
            guard index < arguments.count else { fail("--pane needs a value") }
            target = .pane(arguments[index])
        case "--cwd":
            index += 1
            guard index < arguments.count else { fail("--cwd needs a value") }
            target = .cwd(arguments[index])
        case "--tab":
            wholeTab = true
        case "--help", "-h":
            print(usage)
            exit(0)
        default:
            fail("unknown argument \"\(arguments[index])\"")
        }
        index += 1
    }
    guard let target else { fail("close needs an explicit target: --pane <id> or --cwd <path>") }
    switch roundTrip(.close(target: target, wholeTab: wholeTab)) {
    case .ok: break
    case .error(let message): fail(message)
    default: fail("unexpected response")
    }

case "quit":
    let killSessions = arguments.contains("--kill-sessions")
    switch roundTrip(.quit(killSessions: killSessions)) {
    case .ok: break
    case .error(let message): fail(message)
    default: fail("unexpected response")
    }

case "reload":
    switch roundTrip(.reload) {
    case .ok: print("reloaded")
    case .error(let message): fail(message)
    default: fail("unexpected response")
    }

case "--help", "-h", "help":
    print(usage)

default:
    fail("unknown command \"\(command)\"\n\n\(usage)")
}
