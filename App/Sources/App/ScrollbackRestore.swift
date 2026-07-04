import Foundation
import ZettyCore

/// Writes the scrollback-restore wrapper script (contents owned by
/// `SessionPersistence.restoreScriptContents`) to
/// `~/.zetty/scrollback-restore.sh` — same generated-helper pattern as the
/// agent hook script in `~/.zetty/hooks/`.
enum ScrollbackRestore {

    static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zetty/scrollback-restore.sh")
    }

    /// Ensures the script exists with the current contents (rewrites on
    /// content drift, e.g. after an app update). Returns its path, or nil
    /// when writing fails — the caller then falls back to the bare attach
    /// command, so the pane still preserves; only the replay is lost.
    static func ensureScript() -> String? {
        let url = scriptURL
        let contents = SessionPersistence.restoreScriptContents
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            return url.path
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }
}
