import CryptoKit
import Foundation

/// A layout template, and whether it came from the repo's own
/// `.zetty/project.json` (written by whoever wrote the repo) or from the
/// user's global default (written by the user).
public struct ResolvedLayoutTemplate: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case repoFile, globalDefault }

    public var template: LayoutTemplate
    public var source: Source

    public init(template: LayoutTemplate, source: Source) {
        self.template = template
        self.source = source
    }
}

/// One pane's startup command, with the pane's folder as the template wrote it.
public struct TemplateCommand: Equatable, Sendable {
    public var workingDir: String
    public var command: String

    public init(workingDir: String, command: String) {
        self.workingDir = workingDir
        self.command = command
    }
}

extension LayoutTemplate {
    /// Every pane's startup command, tab by tab, first pane first.
    public var startupCommands: [TemplateCommand] {
        func walk(_ node: TemplateNode) -> [TemplateCommand] {
            switch node {
            case .pane(let workingDir, let command):
                guard let command, !command.isEmpty else { return [] }
                return [TemplateCommand(workingDir: workingDir, command: command)]
            case .split(_, _, let first, let second):
                return walk(first) + walk(second)
            }
        }
        return tabs.flatMap { walk($0.root) }
    }
}

/// The repo startup commands the user agreed to run, per project. A repo's
/// `.zetty/project.json` types its commands into the user's shells, so Zetty
/// asks before the first run and again whenever the commands change: the
/// approval is a fingerprint of exactly what was shown.
public struct StartupCommandTrust: Codable, Equatable, Sendable {
    /// Canonical project root → fingerprint of the commands approved there.
    public var approved: [String: String]

    public init(approved: [String: String] = [:]) {
        self.approved = approved
    }

    /// SHA-256 over each folder and command, length-prefixed so no two
    /// different lists can run together into the same bytes.
    public static func fingerprint(_ commands: [TemplateCommand]) -> String {
        var bytes = Data()
        for entry in commands {
            for field in [entry.workingDir, entry.command] {
                let utf8 = Data(field.utf8)
                bytes.append(Data("\(utf8.count):".utf8))
                bytes.append(utf8)
            }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// No commands need no approval.
    public func allows(_ commands: [TemplateCommand], inProject key: String) -> Bool {
        commands.isEmpty || approved[key] == Self.fingerprint(commands)
    }

    public mutating func approve(_ commands: [TemplateCommand], inProject key: String) {
        approved[key] = Self.fingerprint(commands)
    }
}

/// `startup-command-trust.json` in the app's Application Support directory.
public struct StartupCommandTrustStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("startup-command-trust.json")
    }

    /// Missing or unreadable → nothing approved, so Zetty asks again.
    public func load() -> StartupCommandTrust {
        guard let data = try? Data(contentsOf: fileURL),
              let trust = try? JSONDecoder().decode(StartupCommandTrust.self, from: data)
        else { return StartupCommandTrust() }
        return trust
    }

    public func save(_ trust: StartupCommandTrust) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(trust).write(to: fileURL, options: .atomic)
    }
}

/// How a startup command is shown for approval: everything it would type,
/// with nothing able to hide. Control characters (a carriage return would
/// type a second command) become their Unicode control pictures; characters
/// that reorder, hide or break text (bidirectional controls, zero-width and
/// invisible characters, line separators, unusual spaces) become
/// `<U+XXXX>`; and a run of three or more spaces becomes `<N spaces>`, so
/// padding can't push the rest of a command out of sight. The text read is
/// the text run.
public enum StartupCommandDisplay {
    public static func visible(_ command: String) -> String {
        var out = ""
        var spaces = 0
        func flushSpaces() {
            if spaces >= 3 {
                out += "<\(spaces) spaces>"
            } else {
                out += String(repeating: " ", count: spaces)
            }
            spaces = 0
        }
        for scalar in command.unicodeScalars {
            if scalar == " " {
                spaces += 1
                continue
            }
            flushSpaces()
            switch scalar.value {
            case 0x00...0x1F:
                out.unicodeScalars.append(Unicode.Scalar(0x2400 + scalar.value)!)
            case 0x7F:
                out.unicodeScalars.append(Unicode.Scalar(0x2421)!)
            case 0x80...0xA0, 0x061C, 0x115F, 0x1160, 0x1680, 0x180E, 0x2000...0x200F,
                 0x2028...0x202F, 0x205F...0x206F, 0x3000, 0x3164, 0xFE00...0xFE0F, 0xFEFF,
                 0xFFA0, 0xFFF9...0xFFFB, 0xE0000...0xE007F, 0xE0100...0xE01EF:
                out += String(format: "<U+%04X>", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        flushSpaces()
        return out
    }

    /// One line per command, prefixed by its folder when that is not the
    /// root. Each line is forced left to right (LRO … PDF): right-to-left
    /// letters would otherwise reorder the punctuation around them, and the
    /// line would read in a different order than it is typed.
    public static func lines(_ commands: [TemplateCommand]) -> String {
        commands.map { entry in
            let folder = entry.workingDir == "." || entry.workingDir.isEmpty
                ? "" : "[\(visible(entry.workingDir))] "
            return "\u{202D}\(folder)$ \(visible(entry.command))\u{202C}"
        }.joined(separator: "\n")
    }
}
