import Foundation
import QuerttyCore

/// Runs `git` in a directory to build a ``GitStatus``.
///
/// Blocking — call it off the main thread. Uses `/usr/bin/git` (the macOS shim);
/// if git is missing or the directory isn't a repo, returns ``GitStatus/none``.
enum GitStatusProbe {

    static func probe(directory: String) -> GitStatus {
        guard FileManager.default.fileExists(atPath: directory) else { return .none }

        // rev-parse doubles as the repo check: it fails outside a work tree.
        guard let branchRaw = run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory) else {
            return .none
        }
        var branch = GitStatus.cleanBranch(branchRaw)
        if branch == "HEAD", let sha = run(["rev-parse", "--short", "HEAD"], in: directory) {
            branch = GitStatus.cleanBranch(sha)   // detached → short SHA
        }

        var ahead = 0, behind = 0
        if let ab = run(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], in: directory) {
            (ahead, behind) = GitStatus.parseAheadBehind(ab)
        }

        let changes = run(["status", "--porcelain"], in: directory)
            .map(GitStatus.parseChangeCount) ?? 0

        return GitStatus(branch: branch, ahead: ahead, behind: behind, changes: changes, isRepo: true)
    }

    /// Runs `git -C <dir> <args>`, returning stdout on success (exit 0) or nil.
    private static func run(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // Read to EOF first (the child closes the pipe on exit), so a large
        // porcelain listing can't deadlock against a full pipe buffer.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
