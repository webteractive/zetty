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
    ///
    /// `exists` skips a folder that has gone (a removed worktree, a folder
    /// deleted before a relaunch) for the next one in that order: a split
    /// there started in libghostty's default folder instead (release review,
    /// 2026-11-20). Readers that must not touch the disk leave it out.
    ///
    /// `process` is the shell's own working folder, read from the kernel
    /// (`ProcessDirectory`): no output can fake it, so it comes before OSC 7.
    /// A bash or fish pane writes no cwd file (Zetty's integration is
    /// zsh's), and an OSC 7 that `cat` or a remote host printed picked where
    /// its next split started (security review, 2026-11-20). OSC 7 is left
    /// for a pane with no session to read (a scratch pane).
    public static func choose(cwdFile: StampedPath?, process: StampedPath? = nil,
                              osc7: StampedPath?, agent: StampedPath?,
                              persisted: String?, spawn: String,
                              exists: (String) -> Bool = { _ in true }) -> String {
        let shell = cwdFile ?? process ?? osc7
        let reported = [shell, agent].compactMap { $0 }.filter { !$0.path.isEmpty }
        for candidate in reported.sorted(by: { $0.at > $1.at }) where exists(candidate.path) {
            return candidate.path
        }
        if let persisted, !persisted.isEmpty, exists(persisted) { return persisted }
        return spawn
    }
}
