import Foundation

/// A folder some source reported for a pane, and when (epoch seconds).
public struct StampedPath: Equatable, Sendable {
    public var path: String
    public var at: TimeInterval

    public init(path: String, at: TimeInterval) {
        self.path = path
        self.at = at
    }
}

/// The one rule for "the pane's folder", which every reader uses: the status
/// bar, Open/Reveal, the tab title fallback, the file tree, and new splits.
public enum CurrentDirectory {

    /// The newest folder reported by the shell's cwd file, OSC 7, or the agent
    /// running in the foreground (its own cwd, e.g. a worktree); else the last
    /// one persisted; else the folder the pane was spawned in. Empty paths
    /// count as unreported.
    ///
    /// OSC 7 counts only when the shell writes no cwd file: any program's
    /// output can carry an OSC 7, and this folder is where a new split's
    /// shell starts, so output you merely displayed must not pick it. A shell
    /// with Zetty's integration writes the file and then speaks through it
    /// alone. (The App also drops an OSC 7 naming no local directory.)
    public static func choose(cwdFile: StampedPath?, osc7: StampedPath?, agent: StampedPath?,
                              persisted: String?, spawn: String) -> String {
        let shell = cwdFile ?? osc7
        let reported = [shell, agent].compactMap { $0 }.filter { !$0.path.isEmpty }
        if let newest = reported.max(by: { $0.at < $1.at }) { return newest.path }
        if let persisted, !persisted.isEmpty { return persisted }
        return spawn
    }
}
