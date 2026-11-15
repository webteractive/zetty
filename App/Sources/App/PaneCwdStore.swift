import Foundation
import ZettyCore

/// Bridges the shell's live working directory to the status bar.
///
/// The embedded libghostty (host-managed I/O) is unreliable about surfacing the
/// OSC 7 working-directory action, so Zetty injects `ZETTY_CWD_FILE=<panes>/<id>.cwd`
/// into each pane's environment and the bundled zsh integration writes `$PWD`
/// there on every `cd`. The app reads that file (on the same refresh that a
/// title change triggers) to show the focused pane's live cwd.
///
/// The files are kept across launches: a preserved shell may not prompt again
/// for a long time, and its file is the only record of where it is. Orphans
/// are swept by `reconcileSessions`.
enum PaneCwdStore {

    /// `~/.zetty/panes/` — created on demand.
    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".zetty", isDirectory: true)
            .appendingPathComponent("panes", isDirectory: true)
    }

    /// The cwd file path for a surface (passed to its shell as `ZETTY_CWD_FILE`).
    static func path(for surfaceID: UUID) -> String {
        directory.appendingPathComponent("\(surfaceID.uuidString).cwd").path
    }

    /// Creates the panes directory if needed.
    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The live cwd the shell last wrote for `surfaceID`, or nil if none yet.
    static func read(_ surfaceID: UUID) -> String? {
        let text = try? String(contentsOfFile: path(for: surfaceID), encoding: .utf8)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// The live cwd with the time the shell wrote it (the file's mtime), so it
    /// can be weighed against OSC 7 and the agent's own folder.
    static func readStamped(_ surfaceID: UUID) -> StampedPath? {
        let path = path(for: surfaceID)
        guard let cwd = read(surfaceID),
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        return StampedPath(path: cwd, at: modified.timeIntervalSince1970)
    }

    /// Removes a pane's cwd file (on pane close).
    static func remove(_ surfaceID: UUID) {
        try? FileManager.default.removeItem(atPath: path(for: surfaceID))
    }
}
