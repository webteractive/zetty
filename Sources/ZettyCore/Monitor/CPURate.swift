import Foundation

/// Turns two cumulative-CPU snapshots into a rate.
///
/// `ps`'s own `%cpu` is an average over each process's whole lifetime, so a
/// process that pegged a core an hour ago and has idled since still reports
/// high. For a tool whose purpose is naming the culprit that is confidently
/// wrong, which is why the rate is computed here instead.
public enum CPURate {

    /// Percent of one core consumed between the two samples, or nil when there
    /// is no rate to report yet.
    ///
    /// Values above 100 are real and deliberately not clamped: a parallel build
    /// uses several cores, and hiding that hides the culprit.
    ///
    /// - Parameters:
    ///   - now: pid → cumulative CPU seconds, this tick.
    ///   - previous: the same, last tick. nil on the first sample.
    ///   - elapsed: wallclock seconds between the two.
    public static func percent(now: [Int32: Double],
                               previous: [Int32: Double]?,
                               elapsed: Double) -> Double? {
        guard let previous, elapsed > 0 else { return nil }
        var delta = 0.0
        for (pid, seconds) in now {
            // A pid absent last tick is skipped rather than counted from zero:
            // its lifetime CPU did not happen inside this interval. A pid whose
            // total went DOWN was reused; clamp rather than go negative.
            guard let before = previous[pid] else { continue }
            delta += max(0, seconds - before)
        }
        return delta / elapsed * 100
    }
}
