import Foundation
import ZettyGhostty
import os

/// Structured diagnostics, with two sinks behind one call.
///
/// Some bugs can only be seen on the reporter's machine — the file peek, for
/// one, depends on their colour scheme, their `bat` install, and their file, so
/// "the modal is blank" arrives as a screenshot with nothing in it and no way
/// to tell which of a dozen steps produced the emptiness.
///
/// Every line therefore goes to:
///
/// 1. **`os.Logger`** — persisted by the system, so it can be collected after
///    the fact with `log show --predicate 'subsystem == "co.webteractive.zetty"'`
///    on a release build, with no debug build and nobody watching at the time.
/// 2. **A bounded in-memory ring** — so the app can hand the user their own log
///    directly ("Copy diagnostics" on the peek). That's what turns a bug report
///    from a procedure into a paste, and it's immune to the log store's own
///    rotation, which discards older entries within days.
///
/// `os.Logger` rather than `print`/`NSLog`: free when nobody is reading, and
/// kept on release builds. Messages are plain interpolated strings marked
/// `.public` in one place below — `Logger` redacts dynamic strings by default,
/// and a log full of `<private>` is worth nothing in a bug report. What's
/// recorded is the user's own local state (paths, theme, highlighter), and it
/// stays on their Mac until they choose to paste it.
enum ZettyLog {

    static let subsystem = "co.webteractive.zetty"

    /// The read-only file viewer: path resolution, load, highlight, render.
    static let viewer = ZettyLogger(category: "viewer")

    /// Recent lines, newest last, under a header identifying the build — the
    /// text "Copy diagnostics" puts on the clipboard.
    @MainActor
    static func report() -> String {
        let entries = DiagnosticRing.shared.snapshot()
        let header = """
            Zetty \(TerminalViewController.buildStamp) · \
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \
            \(DiagnosticRing.shared.timestamp(Date()))
            """
        guard !entries.isEmpty else {
            return header + "\n(no diagnostics recorded yet — reproduce the problem first)"
        }
        return ([header] + entries).joined(separator: "\n")
    }
}

/// One category's worth of logging. Mirrors `Logger`'s call shape so a site
/// reads the same either way, but takes a plain `String`: the message has to
/// exist as text for the ring anyway.
struct ZettyLogger {

    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: ZettyLog.subsystem, category: category)
    }

    func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
        DiagnosticRing.shared.append(category: category, message: message, isError: false)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        DiagnosticRing.shared.append(category: category, message: message, isError: true)
    }
}
