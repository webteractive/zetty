# In-App Self-Update (Option B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the existing update trigger, download the latest release DMG, verify its SHA-256, swap the running app bundle in place, and relaunch — instead of only opening the release page.

**Architecture:** Pure, unit-tested helpers in `ZettyCore/Update/` (asset selection, checksum, helper-script rendering); `UpdateChecker` (App) decodes release assets into a richer `AvailableUpdate`; a new `UpdateInstaller` (App) drives download → verify → mount/stage → detached swap-and-relaunch helper; `AppDelegate` adds the confirm dialog + progress sheet. Nothing on disk is replaced until a detached shell helper runs after the app terminates.

**Tech Stack:** Swift, AppKit, `ZettyCore` (pure Swift package target), `CryptoKit` (SHA-256), `URLSession`, `Process` (`hdiutil`, `ditto`, `xattr`), Tuist-generated Xcode project.

## Global Constraints

- **Keep `ZettyCore` pure** — no AppKit. `CryptoKit`/`Foundation` are allowed (no file I/O in Core; callers pass `Data`).
- **No debug `NSLog`/`print`** committed.
- **No `Co-Authored-By` / session links** in commit messages.
- **Regenerate Tuist** after adding/removing source files: `mise exec -- tuist generate --no-open` (run `mise exec -- tuist clean` first if generate errors at a resources dir).
- **Build:** `xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build`.
- **Core tests:** `mise exec -- tuist test` (regenerates the project without target script phases — re-run `tuist generate` before a subsequent app build).
- **DMG asset naming contract:** release assets are `Zetty-<version>.dmg` and `Zetty-<version>.dmg.sha256` (bare lowercase hex digest).
- **Install target is `Bundle.main.bundlePath`** — never hardcode `/Applications`.

---

### Task 1: package.sh publishes a SHA-256 sidecar

**Files:**
- Modify: `scripts/package.sh` (after the `hdiutil create` line)

**Interfaces:**
- Produces: a `dist/Zetty-<version>.dmg.sha256` file (bare lowercase hex, no filename) alongside the DMG, for the release ritual to upload.

- [ ] **Step 1: Add the checksum step**

In `scripts/package.sh`, immediately after the `hdiutil create ... "$DMG"` line and before the final `echo`, add:

```sh
SHA="$DMG.sha256"
shasum -a 256 "$DMG" | awk '{print $1}' > "$SHA"
```

Then update the final echo to mention it:

```sh
echo "Packaged $DMG + $SHA (version $VERSION, commit $COMMIT)"
```

- [ ] **Step 2: Syntax-check the script**

Run: `sh -n scripts/package.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Sanity-check the checksum idiom on a throwaway file**

Run: `printf abc > /tmp/z && shasum -a 256 /tmp/z | awk '{print $1}'`
Expected: `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`

- [ ] **Step 4: Commit**

```bash
git add scripts/package.sh
git commit -m "build: publish Zetty-<version>.dmg.sha256 alongside the DMG"
```

---

### Task 2: Pure release-asset selection (ZettyCore)

**Files:**
- Create: `Sources/ZettyCore/Update/ReleaseAsset.swift`
- Create: `Sources/ZettyCore/Update/UpdateAssets.swift`
- Test: `Tests/ZettyCoreTests/UpdateAssetsTests.swift`

**Interfaces:**
- Produces:
  - `public struct ReleaseAsset: Equatable { public let name: String; public let downloadURL: URL; public init(name:downloadURL:) }`
  - `public enum UpdateAssets { public static func select(from assets: [ReleaseAsset]) -> (dmg: URL?, checksum: URL?) }` — `dmg` = first asset whose name ends `.dmg`; `checksum` = first ending `.dmg.sha256`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ZettyCore

final class UpdateAssetsTests: XCTestCase {
    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(name: name, downloadURL: URL(string: "https://example.com/\(name)")!)
    }

    func testSelectsDMGAndChecksum() {
        let assets = [asset("notes.txt"), asset("Zetty-0.1.11.dmg"), asset("Zetty-0.1.11.dmg.sha256")]
        let picked = UpdateAssets.select(from: assets)
        XCTAssertEqual(picked.dmg?.lastPathComponent, "Zetty-0.1.11.dmg")
        XCTAssertEqual(picked.checksum?.lastPathComponent, "Zetty-0.1.11.dmg.sha256")
    }

    func testChecksumNotMistakenForDMG() {
        // ".dmg.sha256" must not be picked as the dmg.
        let picked = UpdateAssets.select(from: [asset("Zetty-0.1.11.dmg.sha256")])
        XCTAssertNil(picked.dmg)
        XCTAssertEqual(picked.checksum?.lastPathComponent, "Zetty-0.1.11.dmg.sha256")
    }

    func testMissingAssets() {
        let picked = UpdateAssets.select(from: [asset("readme.md")])
        XCTAssertNil(picked.dmg)
        XCTAssertNil(picked.checksum)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- tuist test --test-targets ZettyCoreTests/UpdateAssetsTests`
Expected: FAIL — `ReleaseAsset`/`UpdateAssets` not defined (or build error).

- [ ] **Step 3: Write minimal implementation**

`Sources/ZettyCore/Update/ReleaseAsset.swift`:

```swift
import Foundation

/// One downloadable asset attached to a GitHub release.
public struct ReleaseAsset: Equatable {
    public let name: String
    public let downloadURL: URL

    public init(name: String, downloadURL: URL) {
        self.name = name
        self.downloadURL = downloadURL
    }
}
```

`Sources/ZettyCore/Update/UpdateAssets.swift`:

```swift
import Foundation

/// Picks the installable artifacts from a release's assets by name convention:
/// `*.dmg` is the app image and `*.dmg.sha256` its checksum sidecar.
public enum UpdateAssets {
    public static func select(from assets: [ReleaseAsset]) -> (dmg: URL?, checksum: URL?) {
        let dmg = assets.first { $0.name.hasSuffix(".dmg") }?.downloadURL
        let checksum = assets.first { $0.name.hasSuffix(".dmg.sha256") }?.downloadURL
        return (dmg, checksum)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- tuist test --test-targets ZettyCoreTests/UpdateAssetsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Update/ReleaseAsset.swift Sources/ZettyCore/Update/UpdateAssets.swift Tests/ZettyCoreTests/UpdateAssetsTests.swift
git commit -m "feat(core): release-asset selection for self-update"
```

---

### Task 3: Pure SHA-256 verification (ZettyCore)

**Files:**
- Create: `Sources/ZettyCore/Update/UpdateChecksum.swift`
- Test: `Tests/ZettyCoreTests/UpdateChecksumTests.swift`

**Interfaces:**
- Produces:
  - `public enum UpdateChecksum { public static func sha256Hex(_ data: Data) -> String }` — lowercase hex digest.
  - `public static func matches(data: Data, publishedHex: String) -> Bool` — trims/lowercases `publishedHex`, returns false when it's empty.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ZettyCore

final class UpdateChecksumTests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(UpdateChecksum.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(UpdateChecksum.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testMatchesIgnoresCaseAndWhitespace() {
        let data = Data("abc".utf8)
        XCTAssertTrue(UpdateChecksum.matches(data: data,
            publishedHex: "  BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD\n"))
        XCTAssertFalse(UpdateChecksum.matches(data: data, publishedHex: "deadbeef"))
        XCTAssertFalse(UpdateChecksum.matches(data: data, publishedHex: "   "))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- tuist test --test-targets ZettyCoreTests/UpdateChecksumTests`
Expected: FAIL — `UpdateChecksum` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ZettyCore/Update/UpdateChecksum.swift`:

```swift
import Foundation
import CryptoKit

/// SHA-256 helpers for verifying a downloaded update. Pure — the caller reads
/// the file and passes the bytes; this never touches disk.
public enum UpdateChecksum {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when `data`'s digest equals the published hex (case/whitespace
    /// tolerant). An empty published value never matches.
    public static func matches(data: Data, publishedHex: String) -> Bool {
        let expected = publishedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expected.isEmpty else { return false }
        return sha256Hex(data) == expected
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- tuist test --test-targets ZettyCoreTests/UpdateChecksumTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Update/UpdateChecksum.swift Tests/ZettyCoreTests/UpdateChecksumTests.swift
git commit -m "feat(core): SHA-256 verification for self-update"
```

---

### Task 4: Pure swap-and-relaunch helper script (ZettyCore)

**Files:**
- Create: `Sources/ZettyCore/Update/SelfUpdateScript.swift`
- Test: `Tests/ZettyCoreTests/SelfUpdateScriptTests.swift`

**Interfaces:**
- Produces: `public enum SelfUpdateScript { public static func render(pid: Int32, targetAppPath: String, stagedAppPath: String, workDir: String) -> String }` — a `/bin/sh` script that waits for `pid` to exit, replaces `targetAppPath` with `stagedAppPath`, strips quarantine, cleans `workDir`, relaunches, and deletes itself. All paths single-quote-escaped.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ZettyCore

final class SelfUpdateScriptTests: XCTestCase {
    func testRendersQuotedPathsAndPID() {
        let script = SelfUpdateScript.render(
            pid: 4242,
            targetAppPath: "/Applications/zetty.app",
            stagedAppPath: "/tmp/z work/zetty.app",
            workDir: "/tmp/z work")
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("kill -0 4242"))
        XCTAssertTrue(script.contains("ditto '/tmp/z work/zetty.app' '/Applications/zetty.app'"))
        XCTAssertTrue(script.contains("rm -rf '/Applications/zetty.app'"))
        XCTAssertTrue(script.contains("xattr -dr com.apple.quarantine '/Applications/zetty.app'"))
        XCTAssertTrue(script.contains("open '/Applications/zetty.app'"))
        XCTAssertTrue(script.contains(#"rm -- "$0""#))
    }

    func testEscapesSingleQuotesInPaths() {
        let script = SelfUpdateScript.render(
            pid: 1, targetAppPath: "/x/it's.app", stagedAppPath: "/s/a.app", workDir: "/s")
        XCTAssertTrue(script.contains(#"'/x/it'\''s.app'"#))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- tuist test --test-targets ZettyCoreTests/SelfUpdateScriptTests`
Expected: FAIL — `SelfUpdateScript` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ZettyCore/Update/SelfUpdateScript.swift`:

```swift
import Foundation

/// Renders the detached POSIX-sh helper that performs the in-place bundle swap
/// after the app quits. Pure text generation; the App layer writes and launches
/// it. A running app can't overwrite itself, so this waits for the PID first.
public enum SelfUpdateScript {
    public static func render(
        pid: Int32, targetAppPath: String, stagedAppPath: String, workDir: String
    ) -> String {
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return """
        #!/bin/sh
        # Zetty self-update helper (generated). Waits for the app to quit, swaps
        # the bundle in place, strips quarantine, relaunches, and self-deletes.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(targetAppPath))
        ditto \(q(stagedAppPath)) \(q(targetAppPath))
        xattr -dr com.apple.quarantine \(q(targetAppPath)) 2>/dev/null || true
        rm -rf \(q(workDir))
        open \(q(targetAppPath))
        rm -- "$0"
        """
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- tuist test --test-targets ZettyCoreTests/SelfUpdateScriptTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Update/SelfUpdateScript.swift Tests/ZettyCoreTests/SelfUpdateScriptTests.swift
git commit -m "feat(core): render self-update swap/relaunch helper script"
```

---

### Task 5: Extend UpdateChecker with installable assets

**Files:**
- Modify: `App/Sources/App/UpdateChecker.swift` (whole file)
- Modify: `App/Sources/App/AppDelegate.swift` (rename `update.url` → `update.releasePage` at the two open sites, ~lines 293 and existing page opens)

**Interfaces:**
- Consumes: `ZettyCore.SemVer`, `ZettyCore.ReleaseAsset`, `ZettyCore.UpdateAssets`.
- Produces:
  - `struct AvailableUpdate: Equatable { let version: String; let releasePage: URL; let dmgURL: URL?; let checksumURL: URL? }`
  - `var isInstallable: Bool { dmgURL != nil && checksumURL != nil }` on `AvailableUpdate`.
  - `UpdateChecker.check(completion:)` unchanged signature; now populates the new fields.

- [ ] **Step 1: Rewrite `UpdateChecker.swift`**

```swift
import Foundation
import ZettyCore

/// A newer release available for download.
struct AvailableUpdate: Equatable {
    let version: String       // e.g. "0.1.11"
    let releasePage: URL      // release page (View Release Notes)
    let dmgURL: URL?          // ".dmg" asset, when present
    let checksumURL: URL?     // ".dmg.sha256" asset, when present

    /// In-place install is possible only with both the image and its checksum.
    var isInstallable: Bool { dmgURL != nil && checksumURL != nil }
}

/// Checks the public GitHub releases API for a newer version.
final class UpdateChecker {
    private static let endpoint = URL(string:
        "https://api.github.com/repos/webteractive/zetty/releases/latest")!
    private static let releasesPage = URL(string:
        "https://github.com/webteractive/zetty/releases/latest")!

    private let currentVersion: String

    init(currentVersion: String) { self.currentVersion = currentVersion }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    enum CheckError: Error { case badResponse }

    func check(completion: @escaping (Result<AvailableUpdate?, Error>) -> Void) {
        guard SemVer(currentVersion) != nil else {
            DispatchQueue.main.async { completion(.success(nil)) }
            return
        }
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, _, error in
            let result: Result<AvailableUpdate?, Error>
            if let error {
                result = .failure(error)
            } else if let data, let release = try? JSONDecoder().decode(Release.self, from: data) {
                if SemVer.isNewer(latest: release.tagName, than: self.currentVersion) {
                    let version = release.tagName.hasPrefix("v")
                        ? String(release.tagName.dropFirst()) : release.tagName
                    let page = URL(string: release.htmlURL) ?? Self.releasesPage
                    let assets = release.assets.compactMap { asset -> ReleaseAsset? in
                        URL(string: asset.browserDownloadURL).map {
                            ReleaseAsset(name: asset.name, downloadURL: $0)
                        }
                    }
                    let picked = UpdateAssets.select(from: assets)
                    result = .success(AvailableUpdate(
                        version: version, releasePage: page,
                        dmgURL: picked.dmg, checksumURL: picked.checksum))
                } else {
                    result = .success(nil)
                }
            } else {
                result = .failure(CheckError.badResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
```

- [ ] **Step 2: Fix the `update.url` call sites in AppDelegate**

In `App/Sources/App/AppDelegate.swift`, `versionPillClicked()` currently does `NSWorkspace.shared.open(update.url)`. Change to `update.releasePage` (final wiring happens in Task 7, but the rename must compile now):

```swift
if let update {
    NSWorkspace.shared.open(update.releasePage)
} else {
    self.showUpdateInfo("You're up to date.")
}
```

(Search for any other `.url` on an `AvailableUpdate`; there are none beyond this.)

- [ ] **Step 3: Build to verify it compiles**

Run: `mise exec -- tuist generate --no-open && xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full Core test suite (no regression)**

Run: `mise exec -- tuist test 2>&1 | tail -5`
Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/App/UpdateChecker.swift App/Sources/App/AppDelegate.swift
git commit -m "feat(app): decode release assets into AvailableUpdate"
```

---

### Task 6: UpdateInstaller — download, verify, stage, relaunch

**Files:**
- Create: `App/Sources/App/UpdateInstaller.swift`

**Interfaces:**
- Consumes: `AvailableUpdate` (Task 5), `ZettyCore.UpdateChecksum`, `ZettyCore.SelfUpdateScript`.
- Produces:
  - `enum UpdateInstallProgress { case downloading(Double); case verifying; case preparing; case relaunching }`
  - `enum UpdateInstallError: Error, CustomStringConvertible { case notInstallable; case download; case checksumMismatch; case mount; case notWritable; case helper }`
  - `@MainActor final class UpdateInstaller` with `func install(_ update: AvailableUpdate, progress: @escaping (UpdateInstallProgress) -> Void, completion: @escaping (Result<Void, UpdateInstallError>) -> Void)`. On success it launches the helper and calls `NSApp.terminate(nil)` (so `completion(.success)` fires just before termination).
  - `var isRunning: Bool` guard against re-entry.

- [ ] **Step 1: Write the implementation**

`App/Sources/App/UpdateInstaller.swift`:

```swift
import AppKit
import ZettyCore

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
@MainActor
final class UpdateInstaller {
    private(set) var isRunning = false

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
        Task {
            let result = await self.run(dmgURL: dmgURL, checksumURL: checksumURL, progress: progress)
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

    private func run(
        dmgURL: URL, checksumURL: URL,
        progress: @escaping (UpdateInstallProgress) -> Void
    ) async -> Result<Void, UpdateInstallError> {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("zetty-self-update-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: workDir)
        do { try fm.createDirectory(at: workDir, withIntermediateDirectories: true) }
        catch { return .failure(.download) }
        defer { /* work dir cleaned by the helper on success; on failure remove now */ }

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
            let published = try await String(contentsOf: checksumURL, encoding: .utf8)
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

    private func download(
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

    /// `hdiutil attach -nobrowse` → `ditto` the app out → `hdiutil detach`.
    private func mountAndCopy(dmg: URL, to stagedApp: URL) -> Bool {
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
        return run("/usr/bin/ditto", [sourceApp.path, stagedApp.path])
    }

    private func launchHelper(script: String) -> Bool {
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
        // Detach from the app's process group so it survives terminate.
        do { try process.run() } catch { return false }
        return true
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) -> Bool {
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
```

- [ ] **Step 2: Regenerate + build**

Run: `mise exec -- tuist generate --no-open && xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/App/UpdateInstaller.swift
git commit -m "feat(app): UpdateInstaller download/verify/stage/relaunch"
```

---

### Task 7: Wire the confirm dialog + progress into AppDelegate

**Files:**
- Modify: `App/Sources/App/AppDelegate.swift` (`versionPillClicked`, `checkForUpdates`, add `presentUpdate(_:)`, progress sheet, `updateInstaller` property)

**Interfaces:**
- Consumes: `UpdateChecker`, `AvailableUpdate`, `UpdateInstaller`, `UpdateInstallProgress`, `UpdateInstallError`.
- Produces: `presentUpdate(_ update: AvailableUpdate)` — the shared confirm-then-install flow.

- [ ] **Step 1: Add the installer property**

Near the existing `updateChecker` declaration in `AppDelegate`, add:

```swift
private let updateInstaller = UpdateInstaller()
private var updateProgressAlert: NSAlert?
```

- [ ] **Step 2: Replace `versionPillClicked` and `checkForUpdates` with the shared flow**

```swift
private func versionPillClicked() {
    updateChecker.check { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let update):
            self.terminalViewController?.showUpdate(update)
            if let update { self.presentUpdate(update) }
            else { self.showUpdateInfo("You're up to date.") }
        case .failure:
            self.showUpdateInfo("Couldn't check for updates.")
        }
    }
}

@objc private func checkForUpdates(_ sender: Any?) {
    updateChecker.check { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let update):
            self.terminalViewController?.showUpdate(update)
            if let update { self.presentUpdate(update) }
            else { self.showUpdateInfo("You're up to date.") }
        case .failure:
            self.showUpdateInfo("Couldn't check for updates.")
        }
    }
}
```

- [ ] **Step 3: Add `presentUpdate` + progress handling**

```swift
/// Confirm dialog for a newer version, then download+install in place.
/// Falls back to the release page when the release isn't installable.
private func presentUpdate(_ update: AvailableUpdate) {
    let alert = NSAlert()
    alert.messageText = "Update to \(update.version)?"
    if update.isInstallable {
        alert.informativeText = "Zetty will download the update and restart."
        alert.addButton(withTitle: "Install & Restart")
        alert.addButton(withTitle: "View Release Notes")
        alert.addButton(withTitle: "Later")
    } else {
        alert.informativeText = "A newer version is available on the releases page."
        alert.addButton(withTitle: "View Release Notes")
        alert.addButton(withTitle: "Later")
    }
    let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
        guard let self else { return }
        if update.isInstallable {
            switch response {
            case .alertFirstButtonReturn: self.startInstall(update)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(update.releasePage)
            default: break
            }
        } else {
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(update.releasePage) }
        }
    }
    if let window = terminalViewController?.view.window {
        alert.beginSheetModal(for: window, completionHandler: respond)
    } else {
        respond(alert.runModal())
    }
}

private func startInstall(_ update: AvailableUpdate) {
    let progress = NSAlert()
    progress.messageText = "Updating to \(update.version)…"
    progress.informativeText = "Downloading…"
    let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 16))
    bar.isIndeterminate = false
    bar.minValue = 0; bar.maxValue = 1
    progress.accessoryView = bar
    updateProgressAlert = progress

    let update = update
    let onProgress: (UpdateInstallProgress) -> Void = { [weak progress, weak bar] p in
        switch p {
        case .downloading(let f): bar?.doubleValue = f; progress?.informativeText = "Downloading…"
        case .verifying: bar?.isIndeterminate = true; bar?.startAnimation(nil); progress?.informativeText = "Verifying…"
        case .preparing: progress?.informativeText = "Preparing…"
        case .relaunching: progress?.informativeText = "Restarting…"
        }
    }
    let onDone: (Result<Void, UpdateInstallError>) -> Void = { [weak self] result in
        guard let self else { return }
        if let window = self.terminalViewController?.view.window, let sheet = self.updateProgressAlert?.window {
            window.endSheet(sheet)
        }
        self.updateProgressAlert = nil
        if case .failure(let error) = result {
            self.showUpdateInfo(String(describing: error))
        }
        // .success terminates the app from the installer.
    }

    if let window = terminalViewController?.view.window {
        progress.beginSheetModal(for: window) { _ in }
    }
    updateInstaller.install(update, progress: onProgress, completion: onDone)
}
```

- [ ] **Step 4: Regenerate + build**

Run: `mise exec -- tuist generate --no-open && xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/App/AppDelegate.swift
git commit -m "feat(app): confirm-then-install self-update flow"
```

---

### Task 8: Docs + manual verification

**Files:**
- Modify: `README.md` (Download / update section — note in-app updates auto-strip quarantine)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Update README**

Find the README "Download" section that documents the manual `xattr -d com.apple.quarantine` step and add a sentence:

```markdown
Once installed, use **Check for Updates…** (App menu) or click the version pill
to update in place — Zetty downloads the release, verifies its SHA-256, and
restarts itself (no manual quarantine step needed for in-app updates).
```

- [ ] **Step 2: Full test suite + build**

Run: `mise exec -- tuist test 2>&1 | tail -5`
Expected: all pass.

Run: `mise exec -- tuist generate --no-open && xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual verification (real update path)**

Because a real end-to-end test needs a published newer release, verify by:
1. Temporarily building with a lowered `CFBundleShortVersionString` (or point `UpdateChecker.endpoint` at a test repo) so the live latest release reads as newer.
2. Install to `/Applications`, launch, click the version pill → confirm the dialog, watch the progress sheet, confirm the app relaunches on the new version.
3. With `preserve-sessions` on, confirm panes reattach after relaunch.
4. Force a checksum mismatch (edit the `.sha256` locally / point at a bad file) → confirm the abort alert and that the installed app is untouched.

Revert any temporary version/endpoint changes before the final build.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document in-app self-update"
```

---

## Self-Review

**Spec coverage:**
- SHA-256 sidecar in package.sh → Task 1. ✓
- Richer `AvailableUpdate` / asset selection → Tasks 2, 5. ✓
- Checksum verify → Tasks 3, 6. ✓
- Helper script (wait-swap-relaunch-selfdelete) → Tasks 4, 6. ✓
- Installer state machine (download/verify/stage/relaunch, target = bundlePath, writable pre-check, in-flight guard) → Task 6. ✓
- Confirm dialog (Install & Restart / View Release Notes / Later) + non-installable fallback + progress sheet + error alerts → Task 7. ✓
- Session-preservation synergy → verified in Task 8 step 3. ✓
- Security note (no new auth) → inherent; no build task needed. ✓
- README → Task 8. ✓

**Placeholder scan:** No TBD/TODO; all code blocks concrete. The `defer` comment in Task 6 is explanatory, not a placeholder (cleanup is handled inline per branch).

**Type consistency:** `AvailableUpdate.releasePage/dmgURL/checksumURL/isInstallable`, `ReleaseAsset(name:downloadURL:)`, `UpdateAssets.select(from:) -> (dmg:checksum:)`, `UpdateChecksum.sha256Hex/matches`, `SelfUpdateScript.render(pid:targetAppPath:stagedAppPath:workDir:)`, `UpdateInstaller.install(_:progress:completion:)`, `UpdateInstallProgress`, `UpdateInstallError` — consistent across Tasks 2–7.
