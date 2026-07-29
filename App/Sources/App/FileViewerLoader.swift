import AppKit
import ZettyCore

/// Reads a file and, when a highlight command is configured and installed,
/// runs it to get ANSI-coloured output. All IO happens off-main; the
/// completion is delivered on main.
///
/// Every failure degrades to something showable — a missing `bat` yields plain
/// text, an unreadable file yields a message — because a peek must never
/// present an error dialog.
enum FileViewerLoader {

    struct Loaded {
        let path: String
        let line: Int?
        /// Styled content, or nil when the file couldn't be rendered as text.
        let runs: [ANSIRun]?
        /// Why there's no content (unreadable, missing).
        let message: String?
        /// Line the content was cut at, when it exceeded the line cap.
        let truncatedAtLine: Int?
        /// Set when the file isn't text (binary, or past the size cap): the
        /// viewer has nothing to show, and this says what to do with it instead
        /// — open it, or merely reveal it when launching would install/execute
        /// something. nil means it rendered as text.
        let externalAction: ExternalOpenPolicy.Decision?
    }

    /// Wall-clock ceiling for the highlight subprocess; past it we fall back to
    /// plain text rather than making the user wait on a peek.
    private static let highlightTimeout: TimeInterval = 2.0

    static func load(path: String, line: Int?, highlightCommand: String, maxBytes: Int,
                     completion: @escaping (Loaded) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = loadSync(path: path, line: line,
                                  highlightCommand: highlightCommand, maxBytes: maxBytes)
            DispatchQueue.main.async { completion(loaded) }
        }
    }

    static func loadSync(path: String, line: Int?,
                         highlightCommand: String, maxBytes: Int) -> Loaded {
        func failure(_ message: String) -> Loaded {
            Loaded(path: path, line: line, runs: nil, message: message,
                   truncatedAtLine: nil, externalAction: nil)
        }
        /// Not text — hand it off, but only launch what's safe to launch.
        func external(_ action: ExternalOpenPolicy.Decision) -> Loaded {
            Loaded(path: path, line: line, runs: nil, message: nil,
                   truncatedAtLine: nil, externalAction: action)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return failure("No such file")
        }
        guard !isDirectory.boolValue else { return failure("That's a directory") }
        guard let data = FileManager.default.contents(atPath: path) else {
            return failure("Can't read this file")
        }

        switch FileViewerContent.classify(data, maxBytes: maxBytes) {
        case .binary, .tooLarge:
            return external(ExternalOpenPolicy.decision(path: path, header: data.prefix(8)))
        case .text(let text, let truncatedAtLine):
            // Highlighting reads the file itself, so a truncated body keeps the
            // plain text — the >20k-line case isn't worth a second code path.
            let rendered = truncatedAtLine == nil
                ? highlight(path: path, command: highlightCommand) ?? text
                : text
            return Loaded(path: path, line: line, runs: ANSIText.parse(rendered),
                          message: nil, truncatedAtLine: truncatedAtLine,
                          externalAction: nil)
        }
    }

    /// Runs the highlight command with the file as its final argument. Returns
    /// nil on any failure so the caller falls back to plain text.
    private static func highlight(path: String, command: String) -> String? {
        let parts = command.split(separator: " ").map(String.init)
        guard let tool = parts.first, !tool.isEmpty, let executable = locate(tool) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(parts.dropFirst()) + [path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()   // discard: diagnostics aren't content
        // A highlighter must not inherit a TTY-shaped environment. The child's
        // PATH is the same list `locate` searches, so a tool that was found can
        // also find its own helpers.
        process.environment = ["PATH": binaryDirectories.joined(separator: ":"),
                               "TERM": "xterm-256color"]

        do { try process.run() } catch { return nil }

        // Watchdog: kill a hung highlighter rather than block the peek.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + highlightTimeout, execute: deadline)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()

        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Where a highlight tool may live. A GUI app inherits a minimal `PATH`, so
    /// the search is explicit (the same reason `ZmxRunner.locate()` exists).
    private static var binaryDirectories: [String] {
        [
            "\(NSHomeDirectory())/.zetty/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            "/usr/bin",
            "/bin",
        ]
    }

    /// Resolves a tool name (or an explicit path) to an executable.
    static func locate(_ tool: String) -> String? {
        if tool.contains("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        return binaryDirectories
            .map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

}
