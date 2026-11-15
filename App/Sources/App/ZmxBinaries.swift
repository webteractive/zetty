import Darwin
import Foundation
import ZettyCore

/// Which zmx binary drives which session (session-preservation.md, "The
/// bundled zmx").
///
/// Zetty ships one pinned zmx at `Contents/Helpers/zmx`. Since zmx 1.0 a
/// daemon only talks to clients of its own version, and a client of another
/// version doesn't just fail: a 1.0.1 `kill` or `history` aimed at a 0.6.0
/// daemon hangs (measured 2026-11-13). So:
///
/// - New sessions run a copy of the bundled zmx at `~/.zetty/zmx/<version>/zmx`,
///   a path that outlives app updates, so a later Zetty can still drive them.
/// - Every live session is mapped to a copy of the binary its daemon runs,
///   taken while that binary still exists (a `brew upgrade` would otherwise
///   swap 0.8.1 for 1.0 at the same path and strand its sessions).
/// - A session whose binary is gone is unreachable: nothing runs a zmx
///   command against it.
enum ZmxBinaries {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bundledCopy: String?
    nonisolated(unsafe) private static var bundledVersion: String?
    nonisolated(unsafe) private static var sessionBinaries: [String: String] = [:]
    nonisolated(unsafe) private static var unreachableSessions: Set<String> = []
    nonisolated(unsafe) private static var unreachableDaemonPIDs: [String: Int32] = [:]

    /// `~/.zetty/zmx`. `NSHomeDirectory()` honors `CFFIXED_USER_HOME`, so the
    /// isolated test app keeps its copies under its own home.
    static var storeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".zetty/zmx", isDirectory: true)
    }

    /// The helper inside the running app bundle.
    static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zmx")
    }

    /// The zmx for new sessions, or nil when the bundle's helper is missing or
    /// broken.
    static var forNewSessions: String? {
        lock.lock(); defer { lock.unlock() }
        return bundledCopy
    }

    /// The bundled zmx's version, once `prepare()` ran.
    static var version: String? {
        lock.lock(); defer { lock.unlock() }
        return bundledVersion
    }

    /// The zmx for `session`: the copy of its daemon's binary, or the bundled
    /// copy for a session this map doesn't know (new since launch). nil means
    /// unreachable: its binary is gone, and no other version may touch it.
    static func binary(for session: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if unreachableSessions.contains(session) {
            // Ended since launch (the notice tells the user how): the name is
            // free again, so a pane re-created on it attaches normally.
            guard let pid = unreachableDaemonPIDs[session], Darwin.kill(pid, 0) != 0, errno == ESRCH else {
                return nil
            }
            unreachableSessions.remove(session)
            unreachableDaemonPIDs[session] = nil
        }
        return sessionBinaries[session] ?? bundledCopy
    }

    static func isUnreachable(_ session: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return unreachableSessions.contains(session)
    }

    /// Sessions that are alive but that no zmx here can reach.
    static var unreachable: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return unreachableSessions
    }

    /// Copies the bundled zmx into the store, maps every live Zetty session to
    /// its daemon's binary (copying each version it finds), and prunes copies
    /// nothing uses. Blocking (a `ps`, one `zmx version` per distinct binary,
    /// file copies): run it once at launch, before the first pane.
    static func prepare() {
        let fm = FileManager.default
        var copy: String?
        var version: String?
        var socketDirectory: String?
        if let output = ZmxRunner.runDirect(bundledHelperURL.path, ["version"], timeout: 5),
           let helperVersion = ZmxVersion.parse(versionOutput: output) {
            version = helperVersion
            socketDirectory = ZmxVersion.socketDirectory(versionOutput: output)
            copy = install(bundledHelperURL, version: helperVersion)
        } else {
            ZettyLog.lifecycle.log("zmx: the bundled helper is missing or does not run (\(bundledHelperURL.path))")
        }

        var mapped: [String: String] = [:]
        var unreachable: Set<String> = []
        var daemonPIDs: [String: Int32] = [:]
        var versionsInUse: Set<String> = []
        if let version { versionsInUse.insert(version) }
        let psOutput = ZmxRunner.psSnapshot(timeout: 5)
        let ps = psOutput ?? ""
        var versionByPath: [String: String?] = [:]
        // Only this app's sessions: the process table also holds every other
        // zmx socket folder's daemons (the isolated test app's, the real
        // app's when this is the test app). A session is ours when its
        // socket is in our folder.
        let ours = Set((try? fm.contentsOfDirectory(atPath: socketDirectory ?? "")) ?? [])
        for (session, daemon) in ZmxDaemons.daemons(psOutput: ps) where ours.contains(session) {
            daemonPIDs[session] = daemon.pid
            // The kernel's answer only: argv[0] is not evidence. After a
            // `brew upgrade`, /opt/homebrew/bin/zmx names the new version
            // while the daemon still runs the old one.
            guard let path = trustedExecutable(pid: daemon.pid) else {
                // Its store copy was replaced by a later launch: the store's
                // current copy of that version speaks the same protocol.
                if let kept = replacedStoreCopy(pid: daemon.pid) {
                    versionsInUse.insert(kept.version)
                    mapped[session] = kept.copy
                } else {
                    unreachable.insert(session)
                }
                continue
            }
            let resolved = URL(fileURLWithPath: path)
            guard fm.isExecutableFile(atPath: resolved.path) else {
                unreachable.insert(session)
                continue
            }
            let found = versionByPath[resolved.path] ?? readVersion(resolved.path)
            versionByPath[resolved.path] = found
            guard let found else {
                unreachable.insert(session)
                continue
            }
            versionsInUse.insert(found)
            if found == version, let copy {
                mapped[session] = copy
            } else if let kept = install(resolved, version: found) {
                mapped[session] = kept
            } else {
                unreachable.insert(session)
            }
        }
        if !unreachable.isEmpty {
            ZettyLog.lifecycle.log("zmx: \(unreachable.count) session(s) run a zmx that is gone: \(unreachable.sorted().joined(separator: " "))")
        }
        // Only after a complete look: a failed `ps` or helper `version` finds
        // no daemons, and pruning then would delete the very copies old
        // sessions run from once Homebrew has cleaned up their originals.
        if version != nil, socketDirectory != nil, psOutput != nil {
            prune(keeping: versionsInUse)
        } else {
            ZettyLog.lifecycle.log("zmx: skipped pruning, the scan was incomplete")
        }

        lock.lock()
        bundledCopy = copy
        bundledVersion = version
        sessionBinaries = mapped
        unreachableSessions = unreachable
        unreachableDaemonPIDs = daemonPIDs.filter { unreachable.contains($0.key) }
        lock.unlock()
        ZettyLog.lifecycle.log("zmx: bundled \(version ?? "missing"), \(mapped.count) live session(s) mapped")
    }

    /// The command a pane runs in place of `zmx attach` when its session is
    /// unreachable: a notice that the session is still running and how to end
    /// it, then it waits. Closing the pane leaves the session alone (the kill
    /// is routed, and an unreachable session is never sent one).
    static func unreachableNoticeCommand(session: String) -> String {
        let pid: Int32? = {
            lock.lock(); defer { lock.unlock() }
            return unreachableDaemonPIDs[session]
        }()
        let end = pid.map { "To end it, run: kill \($0)" } ?? "It shows in Activity Monitor as zmx."
        let lines = [
            "The session for this pane (\(session)) is still running, but the zmx",
            "that started it is gone or is not safe to run, so Zetty cannot reattach it.",
            end,
        ]
        // One line of shell: printf's %b turns each \n back into a line break.
        // Single-quoted for /bin/sh; the lines hold no quotes of either kind.
        let message = lines.joined(separator: "\\n")
        return "/bin/sh -c 'printf \"%b\\n\" \"\(message)\"; exec /bin/cat >/dev/null'"
    }

    /// The zmx for a `zetty zmx` command line, without the app: the bundled
    /// copy for commands naming no session (or a session not running yet),
    /// else the binary the named sessions' daemon runs. Never copies or
    /// prunes; the app owns the store. `executable` is the CLI's own binary,
    /// usually reached through the ~/.local/bin symlink.
    static func resolveForCLI(arguments: [String], executable: URL) -> (path: String?, problem: String?) {
        let helper = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent()        // MacOS
            .deletingLastPathComponent()        // Contents
            .appendingPathComponent("Helpers/zmx")
        let bundled: String? = readVersion(helper.path).map { version in
            let copy = storeURL.appendingPathComponent(version).appendingPathComponent("zmx").path
            return FileManager.default.isExecutableFile(atPath: copy) ? copy : helper.path
        }
        let missing = "Zetty's zmx is missing (\(helper.path)); reinstall Zetty"
        if ZmxCommand.usesPattern(arguments) {
            return (nil, "name sessions one by one: zmx expands a trailing * across every session, including ones another zmx version runs, and a mismatched zmx hangs on those")
        }
        let sessions = ZmxCommand.targetSessions(arguments)
        guard !sessions.isEmpty else { return bundled.map { ($0, nil) } ?? (nil, missing) }

        let daemons = ZmxDaemons.daemons(psOutput: ZmxRunner.psSnapshot(timeout: 5) ?? "")
        var chosen: [String] = []
        for session in sessions {
            guard let daemon = daemons[session] else {
                guard let bundled else { return (nil, missing) }
                chosen.append(bundled)
                continue
            }
            let path = trustedExecutable(pid: daemon.pid) ?? replacedStoreCopy(pid: daemon.pid)?.copy ?? ""
            guard FileManager.default.isExecutableFile(atPath: path) else {
                return (nil, "\(session) runs a zmx that is gone, or not owned by you or root, so Zetty won't drive it; to end it: kill \(daemon.pid)")
            }
            chosen.append(path)
        }
        guard Set(chosen).count == 1, let path = chosen.first else {
            return (nil, "those sessions run different zmx versions; name them one at a time")
        }
        return (path, nil)
    }

    // MARK: - Private

    /// The store's copy of `source` for `version`, copied in (atomically) when
    /// missing or different. Copies of the same version are interchangeable:
    /// the protocol is per version, not per file. nil when the copy fails.
    private static func install(_ source: URL, version: String) -> String? {
        let fm = FileManager.default
        let directory = storeURL.appendingPathComponent(version, isDirectory: true)
        let target = directory.appendingPathComponent("zmx")
        if fm.isExecutableFile(atPath: target.path), sameContents(source, target) {
            return target.path
        }
        // A copy of a foreign binary of this version already there is good
        // enough; only the bundled helper insists on its own bytes, so a
        // damaged copy is replaced on the next launch.
        if fm.isExecutableFile(atPath: target.path), source != bundledHelperURL,
           readVersion(target.path) == version {
            return target.path
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".zmx-\(UUID().uuidString)")
            try fm.copyItem(at: source, to: temporary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            _ = try fm.replaceItemAt(target, withItemAt: temporary)
            return target.path
        } catch {
            ZettyLog.lifecycle.log("zmx: could not copy \(source.path) to \(target.path): \(error.localizedDescription)")
            return fm.isExecutableFile(atPath: target.path) && readVersion(target.path) == version ? target.path : nil
        }
    }

    /// Removes version directories no live daemon and not the bundle uses.
    private static func prune(keeping versions: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: storeURL.path) else { return }
        for entry in entries where !entry.hasPrefix(".") && !versions.contains(entry) {
            try? fm.removeItem(at: storeURL.appendingPathComponent(entry, isDirectory: true))
            ZettyLog.lifecycle.log("zmx: pruned unused copy \(entry)")
        }
    }

    private static func sameContents(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let sizeA = (try? fm.attributesOfItem(atPath: a.path))?[.size] as? NSNumber,
              let sizeB = (try? fm.attributesOfItem(atPath: b.path))?[.size] as? NSNumber,
              sizeA == sizeB else { return false }
        return fm.contentsEqual(atPath: a.path, andPath: b.path)
    }

    /// `zmx version`'s version, or nil when the file doesn't run as zmx.
    private static func readVersion(_ path: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path),
              let output = ZmxRunner.runDirect(path, ["version"], timeout: 5) else { return nil }
        return ZmxVersion.parse(versionOutput: output)
    }

    /// For a daemon of this user whose binary was a store copy since
    /// replaced: `proc_pidpath` fails for a deleted executable, but its
    /// mapped region still names the file. The store's copy of the same
    /// version, when that copy is one Zetty may run.
    private static func replacedStoreCopy(pid: Int32) -> (version: String, copy: String)? {
        guard isOwnProcess(pid: pid),
              executablePath(pid: pid) == nil,
              let path = deletedExecutablePath(pid: pid),
              !FileManager.default.fileExists(atPath: path),
              // The kernel's path has symlinks resolved (/tmp is /private/tmp);
              // realpath, since URL.resolvingSymlinksInPath strips /private.
              let store = realpath(storeURL.path, nil).map({ resolved in
                  defer { free(resolved) }
                  return String(cString: resolved)
              }),
              let version = ZmxVersion.storeVersion(ofExecutable: path, store: store) else { return nil }
        let copy = storeURL.appendingPathComponent(version, isDirectory: true).appendingPathComponent("zmx").path
        guard isRunnableByThisUser(copy), FileManager.default.isExecutableFile(atPath: copy) else { return nil }
        return (version, copy)
    }

    /// The executable of a daemon Zetty may run and copy, or nil. Session
    /// names show in `ps` to every account on the Mac, so a process merely
    /// named `zmx attach zetty-…` proves nothing: the daemon must be this
    /// user's, and its binary owned by this user or root and writable by no
    /// one else. Otherwise another account could have its own program run as
    /// this user by Zetty's `zmx version` (security review, 2026-11-13).
    private static func trustedExecutable(pid: Int32) -> String? {
        guard isOwnProcess(pid: pid), let path = executablePath(pid: pid) else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved.hasPrefix("/"), isRunnableByThisUser(resolved) else { return nil }
        return resolved
    }

    /// Whether `pid` runs as this user.
    private static func isOwnProcess(pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == getuid()
    }

    /// Whether the file at `path` (links followed) is one only this user or
    /// root could have put there: owned by one of them, writable by no one else.
    private static func isRunnableByThisUser(_ path: String) -> Bool {
        var status = stat()
        return stat(path, &status) == 0
            && (status.st_uid == getuid() || status.st_uid == 0)
            && status.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    /// The file behind a process's first mapped region, its main binary,
    /// still named after the file is deleted, when `proc_pidpath` fails.
    /// What `lsof` shows as `txt`.
    private static func deletedExecutablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_regionfilename(pid, 0, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The real executable of a running process (symlinks resolved by the
    /// kernel), or nil when it can't be read.
    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
