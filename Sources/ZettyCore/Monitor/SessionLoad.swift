import Foundation

/// What one zmx session is costing right now.
public struct SessionLoad: Equatable, Sendable {
    /// nil on the first tick, or when the session has no live processes —
    /// distinct from 0, which is a measured idle.
    public let cpuPercent: Double?
    /// Summed resident set of the session's own processes. NOT what the pane
    /// costs Zetty: per-pane GPU memory lives inside libghostty and is
    /// unreachable from Swift.
    public let rssBytes: Int64
    public let processCount: Int

    public init(cpuPercent: Double?, rssBytes: Int64, processCount: Int) {
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
        self.processCount = processCount
    }

    public static let none = SessionLoad(cpuPercent: nil, rssBytes: 0, processCount: 0)

    public static func measure(rootPID: Int32,
                               table: ProcessTable,
                               previous: ProcessTable?,
                               elapsed: Double) -> SessionLoad {
        let subtree = table.descendants(of: rootPID)
        guard !subtree.isEmpty else { return .none }

        let now = Dictionary(uniqueKeysWithValues: subtree.map { ($0.pid, $0.cpuSeconds) })
        let before = previous.map { earlier in
            Dictionary(uniqueKeysWithValues: earlier.descendants(of: rootPID)
                .map { ($0.pid, $0.cpuSeconds) })
        }
        return SessionLoad(
            cpuPercent: CPURate.percent(now: now, previous: before, elapsed: elapsed),
            rssBytes: subtree.reduce(0) { $0 + $1.rssBytes },
            processCount: subtree.count
        )
    }
}
