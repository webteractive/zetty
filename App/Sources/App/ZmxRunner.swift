import Foundation
import QuerttyCore

/// Thin process wrapper around the `zmx` binary (session persistence daemon).
///
/// GUI apps don't inherit the shell's PATH, so zmx is located via the standard
/// install directories. All calls are best-effort: a missing binary or failed
/// invocation degrades gracefully (a leftover session is just an orphan the
/// Settings window can clean up).
enum ZmxRunner {

    /// Pinned release downloaded by the in-app installer (from zmx.sh).
    static let version = "0.6.0"

    /// Manual-install guidance shown when the auto-download fails.
    static let installHint = "Download from https://zmx.sh or: brew install neurosnap/tap/zmx"

    /// Where the in-app installer puts the binary.
    static var managedBinaryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".quertty/bin/zmx")
    }

    /// Resolved zmx binary path, or nil when not installed.
    static func locate() -> String? {
        let candidates = [
            managedBinaryURL.path,                      // quertty-managed download
            "/opt/homebrew/bin/zmx",                    // Homebrew (Apple Silicon)
            "/usr/local/bin/zmx",                       // Homebrew (Intel) / manual
            "\(NSHomeDirectory())/.local/bin/zmx",      // manual install
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `zmx list --short` → Zetty session names, both prefixes (empty on any
    /// failure).
    static func listZettySessions(zmxPath: String) -> [String] {
        guard let output = run(zmxPath, ["list", "--short"]) else { return [] }
        return SessionPersistence.zettySessions(fromList: output)
    }

    /// `zmx list` → session name to root shell pid (empty on any failure).
    /// Blocking — call off-main.
    static func sessionPIDs(zmxPath: String) -> [String: Int32] {
        guard let output = run(zmxPath, ["list"]) else { return [:] }
        return SessionPersistence.sessionPIDs(fromList: output)
    }

    /// One process-table snapshot for foreground resolution (nil on failure).
    /// Blocking — call off-main.
    static func psSnapshot() -> String? {
        run("/bin/ps", ["-axo", "pid=,pgid=,stat=,tty=,command="])
    }

    /// `zmx history <session>` — the session's retained scrollback as plain
    /// text (nil when the session doesn't exist). Blocking.
    static func history(session: String, zmxPath: String) -> String? {
        run(zmxPath, ["history", session])
    }

    /// Kills the given sessions in the background (fire-and-forget).
    static func kill(sessions: [String], zmxPath: String) {
        guard !sessions.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = run(zmxPath, ["kill"] + sessions)
        }
    }

    /// Kills the given sessions and waits for zmx to finish — for the quit
    /// path, where an async kill could race app termination.
    static func killAndWait(sessions: [String], zmxPath: String) {
        guard !sessions.isEmpty else { return }
        _ = run(zmxPath, ["kill"] + sessions)
    }

    /// Downloads the pinned zmx release binary from zmx.sh into
    /// `~/.quertty/bin/zmx` (no Homebrew needed). Runs off-main; completion (on
    /// main) gets the resolved zmx path on success, or nil on failure.
    static func install(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let path = downloadAndInstall()
            DispatchQueue.main.async { completion(path) }
        }
    }

    private static func downloadAndInstall() -> String? {
        #if arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x86_64"
        #endif
        let url = "https://zmx.sh/a/zmx-\(version)-macos-\(arch).tar.gz"

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("quertty-zmx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: workDir) }
        let tarball = workDir.appendingPathComponent("zmx.tar.gz")

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            // curl keeps this simple and avoids quarantine-xattr surprises.
            guard run("/usr/bin/curl", ["-fsSL", url, "-o", tarball.path]) != nil else { return nil }
            guard run("/usr/bin/tar", ["-xzf", tarball.path, "-C", workDir.path]) != nil else { return nil }

            // Find the extracted `zmx` binary (archive layout may nest it).
            guard let binary = findBinary(named: "zmx", under: workDir) else { return nil }

            let dest = managedBinaryURL
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: binary, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            return locate()
        } catch {
            return nil
        }
    }

    private static func findBinary(named name: String, under dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }
        for case let url as URL in enumerator
        where url.lastPathComponent == name
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            return url
        }
        return nil
    }

    // MARK: - Private

    /// Runs a binary, returning stdout on exit 0 (nil otherwise). Blocking —
    /// call off-main for anything slow.
    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        // Never run zmx "inside" a session: an inherited ZMX_SESSION (quertty
        // launched from a zmx-backed terminal) changes attach/kill semantics.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZMX_SESSION")
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
