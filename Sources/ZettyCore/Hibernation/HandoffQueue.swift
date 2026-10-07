import Foundation

/// Which panes still owe a handoff, and which forks may run now.
///
/// A value type with no clock and no process, so the order, the cap and
/// cancel are testable; `HandoffRunner` owns one and does what it says.
public struct HandoffQueue: Equatable, Sendable {
    /// Each fork is a cold read of a whole transcript on one account's rate
    /// limit; two at a time finishes a busy project in a third of the serial
    /// worst case without the load spike restart recovery staggers around.
    public static let maxRunning = 2

    public enum Cancelled: Equatable, Sendable { case wasRunning, wasQueued, notPending }

    public private(set) var queued: [UUID] = []
    public private(set) var running: Set<UUID> = []

    public init() {}

    public var isEmpty: Bool { queued.isEmpty && running.isEmpty }
    public func isRunning(_ surface: UUID) -> Bool { running.contains(surface) }
    public func isPending(_ surface: UUID) -> Bool { running.contains(surface) || queued.contains(surface) }
    public func anyPending(among surfaces: [UUID]) -> Bool { surfaces.contains(where: isPending) }

    public mutating func enqueue(_ surfaces: [UUID]) {
        for surface in surfaces where !isPending(surface) { queued.append(surface) }
    }

    /// Moves as many as the cap allows from queued to running, oldest first.
    public mutating func startNext() -> [UUID] {
        var started: [UUID] = []
        while running.count < Self.maxRunning, !queued.isEmpty {
            let surface = queued.removeFirst()
            running.insert(surface)
            started.append(surface)
        }
        return started
    }

    public mutating func finish(_ surface: UUID) { running.remove(surface) }

    /// The caller terminates the process when this answers `.wasRunning`; the
    /// surface is out of `running` either way, which is what makes a late
    /// completion discard its output.
    @discardableResult
    public mutating func cancel(_ surface: UUID) -> Cancelled {
        if running.remove(surface) != nil { return .wasRunning }
        if let index = queued.firstIndex(of: surface) {
            queued.remove(at: index)
            return .wasQueued
        }
        return .notPending
    }
}
