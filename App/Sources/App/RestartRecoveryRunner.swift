import Foundation
import ZettyCore

/// Process and file IO for restart recovery (planning is the pure
/// `RestartRecovery`). `captureSnapshots` blocks and must run off-main;
/// `consumeManifest` and `sweepSnapshots` are small file operations the launch
/// path calls directly.
enum RestartRecoveryRunner {

    private static var zettyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zetty", isDirectory: true)
    }

    /// `~/.zetty/restart-recovery.json` — exists only between a power-off quit
    /// and the next launch.
    static var manifestURL: URL { zettyDirectory.appendingPathComponent("restart-recovery.json") }

    /// `~/.zetty/snapshots/` — one `<session>.vt` per captured pane.
    static var snapshotsDirectory: URL {
        zettyDirectory.appendingPathComponent("snapshots", isDirectory: true)
    }

    static func snapshotPath(for surfaceID: UUID) -> String {
        snapshotsDirectory.appendingPathComponent(RestartRecovery.snapshotFileName(for: surfaceID)).path
    }

    /// Captures `zmx history --vt` for each surface's session, concurrently,
    /// and returns the snapshot paths written within `budget`.
    ///
    /// Each file is written atomically once its own capture completes, so a
    /// capture still running when the budget elapses is simply absent from the
    /// result — it can never leave a partial file. If it finishes later it
    /// leaves a whole file nothing references, which the next launch sweeps.
    static func captureSnapshots(for surfaceIDs: [UUID], zmxPath: String, budget: TimeInterval) -> [UUID: String] {
        guard !surfaceIDs.isEmpty else { return [:] }
        try? FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)

        let lock = NSLock()
        var written: [UUID: String] = [:]
        let group = DispatchGroup()
        for id in surfaceIDs {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let session = SessionPersistence.sessionName(for: id)
                guard let data = ZmxRunner.historyVT(session: session, zmxPath: zmxPath), !data.isEmpty else {
                    ZettyLog.lifecycle.log("snapshot: \(session) skipped (no history)")
                    return
                }
                let path = snapshotPath(for: id)
                // Replaying the raw stream would re-apply the dead agent's
                // terminal modes (alt screen, mouse reporting) into a fresh
                // shell — see SnapshotSanitizer.
                let safe = SnapshotSanitizer.sanitized(snapshot: data)
                do {
                    try safe.write(to: URL(fileURLWithPath: path), options: .atomic)
                } catch {
                    ZettyLog.lifecycle.error("snapshot: \(session) write failed: \(error.localizedDescription)")
                    return
                }
                lock.lock()
                written[id] = path
                lock.unlock()
                ZettyLog.lifecycle.log(
                    "snapshot: \(session) \(data.count) bytes → \(safe.count) sanitized")
            }
        }
        if group.wait(timeout: .now() + budget) == .timedOut {
            ZettyLog.lifecycle.error(
                "snapshot: budget of \(Int(budget))s elapsed; writing manifest with what finished")
        }
        lock.lock(); defer { lock.unlock() }
        return written
    }

    /// Atomic write (temp file + rename via `.atomic`). False on failure — the
    /// caller logs and quits anyway; the next launch is then an ordinary one.
    static func write(_ manifest: RestartRecovery.Manifest) -> Bool {
        guard let data = manifest.encoded() else { return false }
        do {
            try FileManager.default.createDirectory(at: zettyDirectory, withIntermediateDirectories: true)
            try data.write(to: manifestURL, options: .atomic)
            ZettyLog.lifecycle.log("manifest: written with \(manifest.entries.count) entries")
            return true
        } catch {
            ZettyLog.lifecycle.error("manifest: write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Reads and IMMEDIATELY deletes the manifest, so a crash mid-recovery can
    /// never replay it twice. nil when absent, unreadable, or the wrong version
    /// (deleted in those cases too).
    static func consumeManifest() -> RestartRecovery.Manifest? {
        let url = manifestURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let manifest = RestartRecovery.Manifest.decode(data) else {
            ZettyLog.lifecycle.error("manifest: unreadable or unsupported version; ignored")
            return nil
        }
        ZettyLog.lifecycle.log(
            "manifest: consumed, \(manifest.entries.count) entries, written \(manifest.writtenAt)")
        return manifest
    }

    /// Deletes every file in the snapshots directory not in `keeping` —
    /// snapshots of panes the manifest dropped, and late finishers from the
    /// power-off capture.
    static func sweepSnapshots(keeping: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: snapshotsDirectory.path) else {
            return
        }
        var swept = 0
        for name in names {
            let path = snapshotsDirectory.appendingPathComponent(name).path
            guard !keeping.contains(path) else { continue }
            try? FileManager.default.removeItem(atPath: path)
            swept += 1
        }
        if swept > 0 { ZettyLog.lifecycle.log("snapshots: swept \(swept) unreferenced file(s)") }
    }
}
