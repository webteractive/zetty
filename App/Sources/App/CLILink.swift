import AppKit

/// State of the `zetty` CLI symlink relative to *this* app build.
enum CLIStatus {
    case current        // ~/.local/bin/zetty → this build's binary
    case outdated       // symlink exists but points at a different/old build
    case notInstalled   // no symlink

    var needsInstall: Bool { self != .current }
}

/// The `zetty` CLI is this app's binary reached through a symlink at
/// `~/.local/bin/zetty`. Since it's the same binary, "up to date" means the
/// symlink points at the running build; an old/moved build or a missing link is
/// what leaves users on a stale CLI. Shared by Settings and the status bar.
enum CLILink {
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/zetty")
    }

    static func status() -> CLIStatus {
        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        if let dest, dest == Bundle.main.executablePath { return .current }
        // A symlink that exists (even dangling) but doesn't point here is stale.
        if (try? url.checkResourceIsReachable()) == true
            || FileManager.default.fileExists(atPath: url.path)
            || dest != nil {
            return .outdated
        }
        return .notInstalled
    }

    /// (Re)points the symlink at this build's binary. Returns success.
    @discardableResult
    static func install() -> Bool {
        guard let executable = Bundle.main.executablePath else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: url)
        do {
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: executable)
            return true
        } catch {
            return false
        }
    }
}
