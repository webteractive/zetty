import Foundation
import ZettyCore

/// Holds the previous `ps` snapshot so CPU can be differenced, and turns each
/// new one into per-session load.
///
/// Costs nothing while `isActive` is false — the `ps` sweep runs for the
/// foreground probe either way, and this simply ignores it. That is the whole
/// reason the task manager adds no polling: it is a consumer of an existing
/// tick, not a new one.
@MainActor
final class SessionSampler {

    /// Set by the window: true while it is on screen.
    var isActive = false {
        didSet {
            guard !isActive else { return }
            // Dropped on close so reopening starts clean rather than
            // differencing against a snapshot from minutes ago, which would
            // report one enormous rate on the first tick.
            previous = nil
            previousAt = nil
            loads = [:]
        }
    }

    /// Fired after each ingest so the window can redraw.
    var onUpdate: (() -> Void)?

    private(set) var loads: [String: SessionLoad] = [:]
    private var previous: ProcessTable?
    private var previousAt: Date?

    func ingest(psOutput: String, sessionPIDs: [String: Int32], at now: Date) {
        guard isActive else { return }
        let table = ProcessTable(psOutput: psOutput)
        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0

        var measured: [String: SessionLoad] = [:]
        for (session, rootPID) in sessionPIDs {
            measured[session] = SessionLoad.measure(rootPID: rootPID, table: table,
                                                    previous: previous, elapsed: elapsed)
        }
        loads = measured
        // Held even when nothing consumed this tick: dropping it would make
        // every tick look like a first sample and never show a rate.
        previous = table
        previousAt = now
        onUpdate?()
    }
}
