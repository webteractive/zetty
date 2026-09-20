import Foundation

// MARK: - LocationChip

/// The compact stand-in for the status bar's whole left cluster — the working
/// directory and the git state — plus the lines its dropup shows.
///
/// This chip exists for a different reason than the right-hand one. The ambient
/// stats fold away so the WINDOW can get narrower; the left cluster already
/// compresses freely and contributes nothing to the floor. These fold so the
/// information stays READABLE — at a narrow width a truncated branch beside a
/// truncated path is two fragments and no information, where one pill naming
/// the directory and the branch is still an answer.
///
/// It can also afford to change width, which its right-hand counterpart cannot:
/// the left cluster is anchored to the leading edge and the action pills are
/// pinned to the trailing one, so nothing clickable moves when this text grows.
public enum LocationChip {

    /// The directory's last component — the part that identifies it. A status
    /// bar already truncates the head of the path, so the tail is what a reader
    /// is looking at anyway.
    public static func basename(of cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespaces)
        guard trimmed != "/" else { return "/" }
        let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return name.isEmpty ? trimmed : name
    }

    /// What the chip shows: where you are, on what branch, and whether anything
    /// is uncommitted. The counts are left for the dropup — the chip only has
    /// to answer those three.
    public static func label(cwd: String, git: GitStatus) -> String {
        let place = basename(of: cwd)
        guard git.isRepo, !git.branch.isEmpty else { return place }
        let dirty = git.changes > 0 ? " ●" : ""
        guard !place.isEmpty else { return "⎇ \(git.branch)\(dirty)" }
        return "\(place) ⎇ \(git.branch)\(dirty)"
    }

    /// The dropup's lines: the full path and the full git state, neither of
    /// which survives the truncation that made the chip necessary. Only the
    /// non-zero counts appear — a row of zeroes reads as noise.
    public static func detailLines(cwd: String, git: GitStatus) -> [String] {
        var lines: [String] = []
        let path = cwd.trimmingCharacters(in: .whitespaces)
        if !path.isEmpty { lines.append(path) }
        guard git.isRepo, !git.branch.isEmpty else { return lines }
        lines.append("⎇ \(git.branch)")
        if git.ahead > 0 { lines.append("↑\(git.ahead) ahead") }
        if git.behind > 0 { lines.append("↓\(git.behind) behind") }
        if git.changes > 0 { lines.append("●\(git.changes) changed") }
        return lines
    }

    /// Whether the working directory and git should fold into one pill.
    ///
    /// Driven by the window's width, not by leftover space. Measuring leftover
    /// space meant the threshold moved every time an agent ran `cd`, because
    /// the path being measured is part of what is being measured against — so
    /// the bar flapped between layouts while nothing was resized.
    public static func shouldCollapse(windowWidth: Double, wasCollapsed: Bool) -> Bool {
        StatusBarCompaction.isLeftCollapsed(windowWidth: windowWidth,
                                            wasCollapsed: wasCollapsed)
    }
}
