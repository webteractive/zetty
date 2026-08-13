import Foundation

/// A small, thread-safe ring of recent diagnostic lines.
///
/// Exists so the app can hand a user their own log — "Copy diagnostics" on the
/// file peek — instead of asking them to run `log show` in a terminal. It also
/// outlives the system log store's rotation, which discards older entries
/// within days, so a report filed late still carries the session's lines.
///
/// Bounded on purpose: this is a diagnostic tail, not a transcript. Writers can
/// be any thread (the viewer's file load runs off-main), so the lock covers the
/// buffer and the formatter alike — `DateFormatter` is not safe to share
/// unguarded.
public final class DiagnosticRing: @unchecked Sendable {

    public static let shared = DiagnosticRing()

    /// Lines kept. A file peek costs under ten, so this holds a long session's
    /// worth of them while staying trivially small.
    public let capacity: Int

    private let lock = NSLock()
    private var entries: [String] = []

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(capacity: Int = 400) {
        self.capacity = max(1, capacity)
    }

    /// Formats a wall-clock time for a log line.
    public func timestamp(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    /// Appends one line. Errors are marked `!` so a reader can scan for them
    /// without knowing the message texts.
    public func append(category: String, message: String, isError: Bool, at date: Date = Date()) {
        let stamp = timestamp(date)
        lock.lock()
        defer { lock.unlock() }
        entries.append("\(stamp) \(isError ? "!" : " ") \(category)  \(message)")
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// The retained lines, oldest first.
    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
