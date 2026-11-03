import Foundation

/// Finds a zmx session's attached clients in `ps` output, so the serving Mac
/// can nudge its own after a remote client lets go (zmx keeps the size of the
/// client that typed last).
public enum ZmxAttachProcesses {
    /// Pids whose argv has a `zmx` executable, then `attach`, then exactly
    /// `session`, so `zetty-ab12` never matches `zetty-ab12cd34`. Sorted.
    /// `psOutput` is in `ProcessTable.psFormat`.
    public static func pids(attaching session: String, psOutput: String) -> [Int32] {
        ProcessTable(psOutput: psOutput).samples.values.compactMap { sample -> Int32? in
            let argv = sample.command.split(separator: " ").map(String.init)
            guard let at = argv.firstIndex(of: "attach"), at > 0, at + 1 < argv.count,
                  (argv[at - 1] as NSString).lastPathComponent == "zmx",
                  argv[at + 1] == session else { return nil }
            return sample.pid
        }.sorted()
    }
}
