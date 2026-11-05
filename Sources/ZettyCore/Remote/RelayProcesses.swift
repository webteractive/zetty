import Foundation

/// Finds the `zetty attach` relays a viewer's panes run, so closing a remote
/// pane can end its relay before the surface is freed (freeing a surface whose
/// child is mid-write blocks the main thread).
public enum RelayProcesses {
    /// Descendants of `root` whose command line is exactly
    /// `<…/zetty> attach <target>` for a target in `targets`. Sorted.
    /// `psOutput` is in `ProcessTable.psFormat`. Wrappers that merely mention
    /// the command (the pane's login, a grep) never match: argv[0] must be the
    /// zetty binary itself.
    public static func pids(relaying targets: Set<String>, under root: Int32, psOutput: String) -> [Int32] {
        guard !targets.isEmpty else { return [] }
        let samples = ProcessTable(psOutput: psOutput).samples
        func descends(_ pid: Int32) -> Bool {
            var current = pid
            var hops = 0
            while let parent = samples[current]?.ppid, hops < 64 {
                if parent == root { return true }
                if parent <= 1 { return false }
                current = parent
                hops += 1
            }
            return false
        }
        return samples.values.compactMap { sample -> Int32? in
            let argv = sample.command.split(separator: " ").map(String.init)
            guard argv.count == 3, (argv[0] as NSString).lastPathComponent == "zetty",
                  argv[1] == "attach", targets.contains(argv[2]), descends(sample.pid) else { return nil }
            return sample.pid
        }.sorted()
    }
}

/// The `<address>:<pane>` each remote surface's relay was started with, so
/// teardown kills it by what it runs rather than by the machine's address
/// now. A Mac going offline loses its address (`markDisconnected`) before
/// its panes are released, and a lookup then would find nothing to kill.
public struct RelayTargets: Sendable {
    private var bySurface: [UUID: String] = [:]

    public init() {}

    public mutating func record(_ surface: UUID, address: String, pane: String) {
        bySurface[surface] = "\(address):\(pane)"
    }

    /// The targets of `surfaces`, forgotten as they are returned.
    public mutating func take(_ surfaces: Set<UUID>) -> Set<String> {
        Set(surfaces.compactMap { bySurface.removeValue(forKey: $0) })
    }
}
