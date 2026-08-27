import AppKit
import ZettyCore
import ZettyGhostty

enum UpdateInstallProgress {
    case downloading(Double)   // 0.0–1.0
    case verifying
    case preparing
    case relaunching
}

enum UpdateInstallError: Error, CustomStringConvertible {
    case notInstallable
    case download
    case checksumMismatch
    case mount
    case notWritable
    case helper

    var description: String {
        switch self {
        case .notInstallable: "This release has no downloadable app image."
        case .download: "The update download failed."
        case .checksumMismatch: "The downloaded update failed its checksum check."
        case .mount: "The update disk image couldn't be opened."
        case .notWritable: "Zetty can't write to its own location. Move it to a writable folder and try again."
        case .helper: "The updater couldn't start the install helper."
        }
    }
}

/// Downloads a release DMG, verifies its SHA-256, stages the new bundle, then
/// launches a detached helper that swaps it in place after the app quits.
/// Progress and completion are always delivered on the main queue.
///
/// `@unchecked Sendable`: `isRunning` is only read/written on the main queue
/// (in `install` and the completion hop), so the reference is safe to capture
/// in the download `Task`.
final class UpdateInstaller: @unchecked Sendable {
    private(set) var isRunning = false

    /// Call on the main thread. Callbacks fire on the main queue.
    func install(
        _ update: AvailableUpdate,
        progress: @escaping (UpdateInstallProgress) -> Void,
        completion: @escaping (Result<Void, UpdateInstallError>) -> Void
    ) {
        guard !isRunning else { return }
        guard let dmgURL = update.dmgURL, let checksumURL = update.checksumURL else {
            completion(.failure(.notInstallable)); return
        }
        isRunning = true
        let onProgress: (UpdateInstallProgress) -> Void = { p in
            DispatchQueue.main.async { progress(p) }
        }
        Task {
            let result = await UpdateInstaller.run(dmgURL: dmgURL, checksumURL: checksumURL, progress: onProgress)
            DispatchQueue.main.async {
                self.isRunning = false
                switch result {
                case .success:
                    completion(.success(()))
                    NSApp.terminate(nil)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private static func run(
        dmgURL: URL, checksumURL: URL,
        progress: @escaping (UpdateInstallProgress) -> Void
    ) async -> Result<Void, UpdateInstallError> {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("zetty-self-update-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: workDir)
        do { try fm.createDirectory(at: workDir, withIntermediateDirectories: true) }
        catch { return .failure(.download) }

        // Target must be writable BEFORE we touch anything.
        let targetApp = Bundle.main.bundlePath
        let targetParent = (targetApp as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: targetParent) else {
            try? fm.removeItem(at: workDir); return .failure(.notWritable)
        }

        // 1. Download DMG (with progress).
        let dmgPath = workDir.appendingPathComponent("update.dmg")
        do {
            try await download(dmgURL, to: dmgPath) { progress(.downloading($0)) }
        } catch { try? fm.removeItem(at: workDir); return .failure(.download) }

        // 2. Verify checksum.
        progress(.verifying)
        do {
            let published = try await fetchText(checksumURL)
            let bytes = try Data(contentsOf: dmgPath)
            guard UpdateChecksum.matches(data: bytes, publishedHex: published) else {
                try? fm.removeItem(at: workDir); return .failure(.checksumMismatch)
            }
        } catch { try? fm.removeItem(at: workDir); return .failure(.checksumMismatch) }

        // 3. Mount, copy app out, detach.
        progress(.preparing)
        let stagedApp = workDir.appendingPathComponent("zetty.app")
        guard mountAndCopy(dmg: dmgPath, to: stagedApp) else {
            try? fm.removeItem(at: workDir); return .failure(.mount)
        }

        // 4. Write + launch the detached swap helper.
        progress(.relaunching)
        let script = SelfUpdateScript.render(
            pid: ProcessInfo.processInfo.processIdentifier,
            targetAppPath: targetApp,
            stagedAppPath: stagedApp.path,
            workDir: workDir.path)
        guard launchHelper(script: script) else {
            try? fm.removeItem(at: workDir); return .failure(.helper)
        }
        return .success(())
    }

    // MARK: - Steps

    private static func download(
        _ url: URL, to dest: URL, progress: @escaping (Double) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = response.expectedContentLength
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= (1 << 16) {
                try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(received) / Double(total)) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        progress(1.0)
    }

    private static func fetchText(_ url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// `hdiutil attach -nobrowse` → `ditto` the app out → `hdiutil detach`.
    private static func mountAndCopy(dmg: URL, to stagedApp: URL) -> Bool {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("zetty-mnt-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil",
                  ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path])
        else { return false }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? FileManager.default.removeItem(at: mountPoint)
        }
        let sourceApp = mountPoint.appendingPathComponent("zetty.app")
        guard FileManager.default.fileExists(atPath: sourceApp.path) else { return false }
        guard run("/usr/bin/ditto", [sourceApp.path, stagedApp.path]) else { return false }
        // Verify here, while the app is still alive and the failure can reach
        // the user as an error. Once the helper is launched the old bundle is
        // moved aside, and a staged copy that turns out to be incomplete is
        // only recoverable by a rollback the user never sees.
        return bundleIsComplete(at: stagedApp)
    }

    /// A bundle is usable only if every path the loader needs actually landed.
    /// Shares its list with the swap helper (`SelfUpdateScript`).
    private static func bundleIsComplete(at app: URL) -> Bool {
        SelfUpdateScript.requiredBundlePaths.allSatisfy {
            FileManager.default.fileExists(atPath: app.appendingPathComponent($0).path)
        }
    }

    private static func launchHelper(script: String) -> Bool {
        let scriptURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".zetty/self-update.sh")
        do {
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        do { try process.run() } catch { return false }
        return true
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
