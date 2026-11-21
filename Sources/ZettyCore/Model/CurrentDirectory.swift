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

    /// The newest folder reported by the shell (its cwd file, else its own
    /// working folder read from the kernel) or by the agent running in the
    /// foreground (its own cwd, e.g. a worktree); else the last one
    /// persisted; else the folder the pane was spawned in. Empty paths count
    /// as unreported.
    ///
    /// OSC 7 never counts: any program's output can carry one, and this
    /// folder is where a new split's shell starts. A shell with Zetty's
    /// integration (zsh) writes the cwd file; every pane with a session has
    /// a shell whose folder `ProcessDirectory` reads, which no output can
    /// fake. OSC 7 once filled the gap for bash and fish panes, and output
    /// that `cat` or a remote host printed picked where their next split
    /// started (security reviews, 2026-11-20 and of 9e58763..cb4df1b). A
    /// bash or fish pane with no session now keeps its persisted or spawn
    /// folder.
    ///
    /// `exists` skips a folder that has gone (a removed worktree, a folder
    /// deleted before a relaunch) for the next one in that order: a split
    /// there started in libghostty's default folder instead (release review,
    /// 2026-11-20). Readers that must not touch the disk leave it out.
    public static func choose(cwdFile: StampedPath?, process: StampedPath? = nil,
                              agent: StampedPath?,
                              persisted: String?, spawn: String,
                              exists: (String) -> Bool = { _ in true }) -> String {
        let shell = cwdFile ?? process
        let reported = [shell, agent].compactMap { $0 }.filter { !$0.path.isEmpty }
        for candidate in reported.sorted(by: { $0.at > $1.at }) where exists(candidate.path) {
            return candidate.path
        }
        if let persisted, !persisted.isEmpty, exists(persisted) { return persisted }
        return spawn
    }
}
