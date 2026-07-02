import Foundation

/// Wire protocol between the `quertty` CLI and the app's control socket
/// (`~/.quertty/quertty.sock`): one JSON object per line, one request →
/// one response per connection. Pure and shared by both sides.

// MARK: - Requests

public enum ControlRequest: Equatable, Sendable {
    case status
    case reload
    /// Inject input into a pane: `text` first (verbatim), then each key in
    /// `keys` (see `KeyNotation`), then a carriage return when `enter` is set.
    case send(target: PaneSelector, text: String?, enter: Bool, keys: [String])
    /// Open a new tab in the named project (nil → the active project); the
    /// response is `.pane` with the new pane's short id.
    case newTab(project: String?)
    /// Close the targeted pane (its tab when it's the last pane), or the
    /// whole tab containing it when `wholeTab` is set.
    case close(target: PaneSelector, wholeTab: Bool)
    /// Quit the app (bypasses the quit confirmation — the CLI call IS the
    /// confirmation). With `killSessions`, every preserved zmx session is
    /// killed first: a full shutdown, nothing survives to reattach.
    case quit(killSessions: Bool)
    /// Split the targeted pane (vertical = side by side); the response is
    /// `.pane` with the new pane's short id.
    case split(target: PaneSelector, vertical: Bool)
    /// Focus the targeted pane (selecting its project/tab).
    case focus(target: PaneSelector)
    /// The targeted pane's recent output (`lines` from the end; nil → all
    /// retained scrollback). Requires the pane's preserved zmx session.
    case capture(target: PaneSelector, lines: Int?)
}

extension ControlRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case command, target, text, enter, keys, project, wholeTab, killSessions, vertical, lines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .command) {
        case "status": self = .status
        case "reload": self = .reload
        case "send":
            self = .send(
                target: try container.decodeIfPresent(PaneSelector.self, forKey: .target) ?? .focused,
                text: try container.decodeIfPresent(String.self, forKey: .text),
                enter: try container.decodeIfPresent(Bool.self, forKey: .enter) ?? false,
                keys: try container.decodeIfPresent([String].self, forKey: .keys) ?? []
            )
        case "new-tab":
            self = .newTab(project: try container.decodeIfPresent(String.self, forKey: .project))
        case "close":
            self = .close(
                target: try container.decode(PaneSelector.self, forKey: .target),
                wholeTab: try container.decodeIfPresent(Bool.self, forKey: .wholeTab) ?? false
            )
        case "quit":
            self = .quit(killSessions: try container.decodeIfPresent(Bool.self, forKey: .killSessions) ?? false)
        case "split":
            self = .split(
                target: try container.decodeIfPresent(PaneSelector.self, forKey: .target) ?? .focused,
                vertical: try container.decodeIfPresent(Bool.self, forKey: .vertical) ?? true
            )
        case "focus":
            self = .focus(target: try container.decode(PaneSelector.self, forKey: .target))
        case "capture":
            self = .capture(
                target: try container.decodeIfPresent(PaneSelector.self, forKey: .target) ?? .focused,
                lines: try container.decodeIfPresent(Int.self, forKey: .lines)
            )
        case let other:
            throw ControlError.protocolError("unknown command \"\(other)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status:
            try container.encode("status", forKey: .command)
        case .reload:
            try container.encode("reload", forKey: .command)
        case .send(let target, let text, let enter, let keys):
            try container.encode("send", forKey: .command)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encode(enter, forKey: .enter)
            try container.encode(keys, forKey: .keys)
        case .newTab(let project):
            try container.encode("new-tab", forKey: .command)
            try container.encodeIfPresent(project, forKey: .project)
        case .close(let target, let wholeTab):
            try container.encode("close", forKey: .command)
            try container.encode(target, forKey: .target)
            try container.encode(wholeTab, forKey: .wholeTab)
        case .quit(let killSessions):
            try container.encode("quit", forKey: .command)
            try container.encode(killSessions, forKey: .killSessions)
        case .split(let target, let vertical):
            try container.encode("split", forKey: .command)
            try container.encode(target, forKey: .target)
            try container.encode(vertical, forKey: .vertical)
        case .focus(let target):
            try container.encode("focus", forKey: .command)
            try container.encode(target, forKey: .target)
        case .capture(let target, let lines):
            try container.encode("capture", forKey: .command)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(lines, forKey: .lines)
        }
    }
}

// MARK: - Responses

public enum ControlResponse: Equatable, Sendable {
    case ok
    case status(StatusSnapshot)
    /// A pane short id (e.g. the pane created by `new-tab` or `split`).
    case pane(String)
    /// Captured pane output.
    case text(String)
    case error(String)
}

extension ControlResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case ok, status, pane, text, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let message = try container.decodeIfPresent(String.self, forKey: .error) {
            self = .error(message)
        } else if let snapshot = try container.decodeIfPresent(StatusSnapshot.self, forKey: .status) {
            self = .status(snapshot)
        } else if let pane = try container.decodeIfPresent(String.self, forKey: .pane) {
            self = .pane(pane)
        } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else {
            self = .ok
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode(true, forKey: .ok)
        case .status(let snapshot):
            try container.encode(true, forKey: .ok)
            try container.encode(snapshot, forKey: .status)
        case .pane(let id):
            try container.encode(true, forKey: .ok)
            try container.encode(id, forKey: .pane)
        case .text(let text):
            try container.encode(true, forKey: .ok)
            try container.encode(text, forKey: .text)
        case .error(let message):
            try container.encode(false, forKey: .ok)
            try container.encode(message, forKey: .error)
        }
    }
}

// MARK: - Status payload

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public struct Pane: Codable, Equatable, Sendable {
        public let id: String            // 8-hex short surface id (zmx session suffix)
        public let title: String?        // last emitted terminal title
        public let cwd: String?
        public let tool: String?         // probed foreground command
        public let agentStatus: String?  // running / idle / needsAttention
        public let isFocused: Bool       // focused pane of the active tab

        public init(id: String, title: String?, cwd: String?, tool: String?, agentStatus: String?, isFocused: Bool) {
            self.id = id
            self.title = title
            self.cwd = cwd
            self.tool = tool
            self.agentStatus = agentStatus
            self.isFocused = isFocused
        }
    }

    public struct Tab: Codable, Equatable, Sendable {
        public let title: String
        public let isActive: Bool
        public let panes: [Pane]

        public init(title: String, isActive: Bool, panes: [Pane]) {
            self.title = title
            self.isActive = isActive
            self.panes = panes
        }
    }

    public struct Project: Codable, Equatable, Sendable {
        public let name: String
        public let isActive: Bool
        public let tabs: [Tab]

        public init(name: String, isActive: Bool, tabs: [Tab]) {
            self.name = name
            self.isActive = isActive
            self.tabs = tabs
        }
    }

    public let projects: [Project]

    public init(projects: [Project]) {
        self.projects = projects
    }

    /// Every pane across all projects/tabs, in display order.
    public var panes: [Pane] {
        projects.flatMap { $0.tabs.flatMap(\.panes) }
    }
}

// MARK: - Pane selection

public enum PaneSelector: Equatable, Sendable {
    /// The focused pane of the active tab (the default target).
    case focused
    /// A pane by unique short-id prefix (4+ hex chars recommended).
    case pane(String)
    /// The single pane whose working directory matches `path`.
    case cwd(String)

    public func resolve(in panes: [StatusSnapshot.Pane]) throws -> StatusSnapshot.Pane {
        switch self {
        case .focused:
            guard let pane = panes.first(where: \.isFocused) ?? panes.first else {
                throw ControlError.noSuchPane("no panes open")
            }
            return pane
        case .pane(let prefix):
            let needle = prefix.lowercased()
            let matches = panes.filter { $0.id.lowercased().hasPrefix(needle) }
            guard !matches.isEmpty else { throw ControlError.noSuchPane("no pane matches id \"\(prefix)\"") }
            guard matches.count == 1 else {
                throw ControlError.ambiguous("id \"\(prefix)\" matches \(matches.count) panes")
            }
            return matches[0]
        case .cwd(let path):
            let needle = Self.normalize(path)
            let matches = panes.filter { $0.cwd.map(Self.normalize) == needle }
            guard !matches.isEmpty else { throw ControlError.noSuchPane("no pane in \(path)") }
            guard matches.count == 1 else {
                throw ControlError.ambiguous("\(matches.count) panes are in \(path) — target by id")
            }
            return matches[0]
        }
    }

    private static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }
}

extension PaneSelector: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "focused": self = .focused
        case "pane": self = .pane(try container.decode(String.self, forKey: .value))
        case "cwd": self = .cwd(try container.decode(String.self, forKey: .value))
        case let other: throw ControlError.protocolError("unknown selector \"\(other)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .focused:
            try container.encode("focused", forKey: .kind)
        case .pane(let id):
            try container.encode("pane", forKey: .kind)
            try container.encode(id, forKey: .value)
        case .cwd(let path):
            try container.encode("cwd", forKey: .kind)
            try container.encode(path, forKey: .value)
        }
    }
}

// MARK: - Errors + framing

public enum ControlError: Error, Equatable, LocalizedError {
    case protocolError(String)
    case noSuchPane(String)
    case ambiguous(String)

    public var errorDescription: String? {
        switch self {
        case .protocolError(let m), .noSuchPane(let m), .ambiguous(let m): return m
        }
    }
}

/// One-JSON-object-per-line framing helpers.
public enum ControlWire {
    public static func encodeLine(_ request: ControlRequest) throws -> String {
        String(data: try JSONEncoder().encode(request), encoding: .utf8)! + "\n"
    }

    public static func encodeLine(_ response: ControlResponse) throws -> String {
        String(data: try JSONEncoder().encode(response), encoding: .utf8)! + "\n"
    }

    public static func decodeRequest(_ line: String) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: Data(line.utf8))
    }

    public static func decodeResponse(_ line: String) throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
    }
}
