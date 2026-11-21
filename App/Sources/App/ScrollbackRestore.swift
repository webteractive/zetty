import Darwin
import Foundation
import ZettyCore
import ZettyGhostty

/// Writes the scrollback-restore wrapper script (contents owned by
/// `SessionPersistence.restoreScriptContents`) to
/// `~/.zetty/scrollback-restore.sh` — same generated-helper pattern as the
/// agent hook script in `~/.zetty/hooks/`.
enum ScrollbackRestore {

    static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zetty/\(SessionPersistence.restoreScriptName)")
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

    /// Writes `~/.zetty/session-shell.sh` (`SessionPersistence.sessionShellContents`)
    /// and pairs it with the account's login shell, the one a pane's
    /// `login -fl` starts. nil when it can't be written, or when either path
    /// would need quoting in ghostty's `command`: new sessions then start
    /// their shell as zmx does, with the no-detach key in it.
    static func sessionShell() -> SessionPersistence.SessionShell? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zetty/\(SessionPersistence.sessionShellName)")
        let contents = SessionPersistence.sessionShellContents
        let fm = FileManager.default
        if (try? String(contentsOf: url, encoding: .utf8)) != contents {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }
        // zmx execs it directly, so it must be executable.
        guard (try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)) != nil else { return nil }
        var loginShell = "/bin/zsh"
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell, !String(cString: shell).isEmpty {
            loginShell = String(cString: shell)
        }
        guard !url.path.contains(" "), !loginShell.contains(" ") else { return nil }
        return SessionPersistence.SessionShell(wrapperPath: url.path, loginShell: loginShell)
    }
}
