# Update Notification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** [`docs/plans/2026-07-06-update-notification-design.md`](../../plans/2026-07-06-update-notification-design.md)

**Goal:** Notify the user when a newer Zetty release exists — a status-bar pill + App-menu "Check for Updates…" that link to the release page — by polling the public GitHub releases API.

**Architecture:** A pure, tested `SemVer` compare in `ZettyCore` and a new reserved `check-updates` config key. An app-layer `UpdateChecker` (URLSession) fetches the latest release, compares versions, and drives a status-bar pill; `AppDelegate` runs launch/periodic/manual checks.

**Tech Stack:** Swift, AppKit (App target), swift-testing for `ZettyCore`, URLSession, Tuist.

## Global Constraints

- **Keep `ZettyCore` pure** — `SemVer` uses only Foundation; no networking in core.
- **Never hardcode a color** — the pill reads `ZTheme.current.<token>Color`; terminal-adjacent chrome uses `ZTheme.monoFont`.
- **No debug `NSLog`/`print`** in committed code.
- **No secrets** — the GitHub endpoint is unauthenticated/public; no token in the app.
- **Commits require Glen's approval** — each "Commit" step means stage + ask.
- **New source files** (`SemVer.swift`, `UpdateChecker.swift`) → run `mise exec -- tuist generate --no-open` before building; if a bogus "Manifest not found …/AgentLogos" error appears, run `mise exec -- tuist clean` first.
- **Run core tests** with `swift test`. Build the app with `xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build`.
- **Endpoint:** `https://api.github.com/repos/webteractive/zetty/releases/latest`.

---

### Task 1: `SemVer` compare (pure core)

**Files:**
- Create: `Sources/ZettyCore/Version/SemVer.swift`
- Test: `Tests/ZettyCoreTests/SemVerTests.swift`

**Interfaces:**
- Produces: `struct SemVer: Comparable, Equatable { init?(_ string: String) }` and `static func SemVer.isNewer(latest: String, than current: String) -> Bool`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ZettyCoreTests/SemVerTests.swift
import Testing
@testable import ZettyCore

@Test func semverParsesAndStripsVPrefix() {
    #expect(SemVer("v0.1.7") == SemVer("0.1.7"))
    #expect(SemVer("1.2.3") != nil)
    #expect(SemVer("dev") == nil)
    #expect(SemVer("") == nil)
    #expect(SemVer("1.2") == SemVer("1.2.0"))   // missing patch → 0
}

@Test func semverOrders() {
    #expect(SemVer("0.1.6")! < SemVer("0.1.7")!)
    #expect(SemVer("0.2.0")! > SemVer("0.1.9")!)
    #expect(SemVer("1.0.0")! > SemVer("0.9.9")!)
}

@Test func isNewerHandlesPrefixEqualAndGarbage() {
    #expect(SemVer.isNewer(latest: "v0.1.7", than: "0.1.6"))
    #expect(!SemVer.isNewer(latest: "0.1.6", than: "0.1.6"))   // equal → not newer
    #expect(!SemVer.isNewer(latest: "0.1.5", than: "0.1.6"))   // older → not newer
    #expect(!SemVer.isNewer(latest: "0.1.7", than: "dev"))     // unparseable current → never nag
    #expect(!SemVer.isNewer(latest: "garbage", than: "0.1.6")) // unparseable latest → no
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- tuist generate --no-open && swift test --filter SemVerTests`
Expected: FAIL — `SemVer` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ZettyCore/Version/SemVer.swift
import Foundation

/// A minimal `MAJOR.MINOR.PATCH` version for update comparisons. Tolerates a
/// leading `v` and a missing patch; anything else fails to parse (nil).
public struct SemVer: Comparable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 1, parts.count <= 3 else { return nil }
        var nums: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            nums.append(n)
        }
        major = nums[0]
        minor = nums.count > 1 ? nums[1] : 0
        patch = nums.count > 2 ? nums[2] : 0
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// True only when both parse and `latest` is strictly greater than `current`.
    public static func isNewer(latest: String, than current: String) -> Bool {
        guard let l = SemVer(latest), let c = SemVer(current) else { return false }
        return l > c
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SemVerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Version/SemVer.swift Tests/ZettyCoreTests/SemVerTests.swift
git commit -m "feat(core): SemVer compare for update checks"
```

---

### Task 2: `check-updates` config key

**Files:**
- Modify: `Sources/ZettyCore/Config/AppConfig.swift` (property, init param+assign, parse case, serialization)
- Test: `Tests/ZettyCoreTests/AppConfigTests.swift`

**Interfaces:**
- Produces: `AppConfig.checkUpdates: Bool` (default true), parsed from `check-updates`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ZettyCoreTests/AppConfigTests.swift`:

```swift
@Test func configParsesCheckUpdates() {
    #expect(AppConfig.parse("").checkUpdates == true)            // default on
    #expect(AppConfig.parse("check-updates = false").checkUpdates == false)
    #expect(AppConfig.parse("check-updates = true").checkUpdates == true)
}
```

> If the existing tests call the parser differently (e.g. `AppConfig.parse(text:)` or `ConfigStore`), match that call convention — check the top of `AppConfigTests.swift` first and mirror it.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppConfigTests`
Expected: FAIL — `checkUpdates` undefined.

- [ ] **Step 3: Write minimal implementation**

In `AppConfig.swift`, add the property near `confirmQuit` (~line 63):

```swift
    /// Poll GitHub for newer releases and show an update pill (default true).
    /// Only gates automatic checks; the manual menu item always runs.
    public var checkUpdates: Bool
```

Add init param after `confirmQuit: Bool = true,` (~line 92):

```swift
        checkUpdates: Bool = true,
```

Assign in the init body after `self.confirmQuit = confirmQuit` (~line 106):

```swift
        self.checkUpdates = checkUpdates
```

Add the parse case after `confirm-quit` (~line 157):

```swift
            case "check-updates":
                config.checkUpdates = ["true", "yes", "on", "1"].contains(value.lowercased())
```

Add to the serialized default text near `confirm-quit = …` (~line 245):

```swift
        check-updates = \(checkUpdates)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZettyCore/Config/AppConfig.swift Tests/ZettyCoreTests/AppConfigTests.swift
git commit -m "feat(core): check-updates config key"
```

---

### Task 3: `UpdateChecker` (app layer)

**Files:**
- Create: `App/Sources/App/UpdateChecker.swift`

**Interfaces:**
- Consumes: `SemVer.isNewer` (Task 1).
- Produces: `struct AvailableUpdate: Equatable { let version: String; let url: URL }` and `final class UpdateChecker { init(currentVersion: String); func check(completion: @escaping (Result<AvailableUpdate?, Error>) -> Void) }`.

- [ ] **Step 1: Implement**

```swift
// App/Sources/App/UpdateChecker.swift
import Foundation
import ZettyCore

/// A newer release available for download.
struct AvailableUpdate: Equatable {
    let version: String   // e.g. "0.1.7"
    let url: URL          // release page
}

/// Checks the public GitHub releases API for a newer version. Notify-only.
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
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    enum CheckError: Error { case badResponse }

    /// Fetches the latest release; completion runs on the main queue with an
    /// `AvailableUpdate` when newer, `nil` when up to date, or an error.
    func check(completion: @escaping (Result<AvailableUpdate?, Error>) -> Void) {
        // A dev/unparseable current version can never be "behind" — skip.
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
                    let url = URL(string: release.htmlURL) ?? Self.releasesPage
                    result = .success(AvailableUpdate(version: version, url: url))
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

- [ ] **Step 2: Build**

Run: `mise exec -- tuist generate --no-open && xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/App/UpdateChecker.swift
git commit -m "feat(app): UpdateChecker — poll GitHub releases, compare version"
```

---

### Task 4: Status-bar pill + App-menu item + wiring

**Files:**
- Modify: `App/Sources/App/StatusBarView.swift` (add the update pill + `setUpdate` + `onUpdateClicked`)
- Modify: `App/Sources/App/AppDelegate.swift` (menu item, `UpdateChecker`, launch/periodic/manual checks, config gate, open URL, feed the pill)

**Interfaces:**
- Consumes: `UpdateChecker`, `AvailableUpdate` (Task 3); `appConfig.checkUpdates` (Task 2).
- Produces: `StatusBarView.setUpdate(_:)`, `StatusBarView.onUpdateClicked`.

- [ ] **Step 1: Add the pill to `StatusBarView`**

Add a stored button near the other right-side controls (by `zettyLabel`, ~line 52):

```swift
    /// "Update available" pill — hidden unless a newer release exists.
    private let updateButton = NSButton()
    var onUpdateClicked: (() -> Void)?
```

In the view's setup (where the right-side controls are configured/added — mirror `editorButton`), configure it:

```swift
        updateButton.isBordered = false
        updateButton.wantsLayer = true
        updateButton.layer?.cornerRadius = 9
        updateButton.font = ZTheme.monoFont(size: 11)
        updateButton.contentTintColor = ZTheme.current.accentColor
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        updateButton.isHidden = true
```

Add it to the right-side stack (leading of `zettyLabel`, so it reads first), the action, and the setter:

```swift
    @objc private func updateClicked() { onUpdateClicked?() }

    /// Shows/hides the update pill. `nil` hides it.
    func setUpdate(_ update: AvailableUpdate?) {
        if let update {
            updateButton.title = " ↑ Update \(update.version) "
            updateButton.layer?.backgroundColor = ZTheme.current.bg3Color.cgColor
            updateButton.contentTintColor = ZTheme.current.accentColor
            updateButton.isHidden = false
        } else {
            updateButton.isHidden = true
        }
    }
```

> Match how the existing right-side controls are laid out — if they're in an `NSStackView`, `addArrangedSubview(updateButton)` at the appropriate index; if pinned with constraints, pin `updateButton` to the left of `zettyLabel`. Check the surrounding layout code and follow it.

- [ ] **Step 2: Wire the checker + menu in `AppDelegate`**

Add a stored checker + accessor for the status bar. Near other properties:

```swift
    private lazy var updateChecker = UpdateChecker(
        currentVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
    private var updateTimer: Timer?
```

Add the menu item to the app menu (after `settingsItem`, ~line 1027):

```swift
        let checkUpdates = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkUpdates.target = self
        appMenu.addItem(checkUpdates)
```

Wire the pill click (where the status bar is created/owned — the TVC exposes it, or AppDelegate reaches `terminalViewController?.statusBarView`; mirror how other status-bar callbacks are wired). Set:

```swift
        // when the status bar exists:
        statusBar.onUpdateClicked = { [weak self] in self?.openLatestRelease() }
```

Add the check + schedule logic:

```swift
    /// Auto-check on launch/timer, gated by config + a 6h throttle.
    private func startUpdateChecks() {
        guard appConfig.checkUpdates else { return }
        runUpdateCheckIfDue()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.runUpdateCheckIfDue()
        }
    }

    private func runUpdateCheckIfDue() {
        let key = "Zetty.lastUpdateCheck"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard now - last >= 6 * 3600 else { return }
        UserDefaults.standard.set(now, forKey: key)
        updateChecker.check { [weak self] result in
            if case .success(let update) = result { self?.applyUpdate(update) }
        }
    }

    private func applyUpdate(_ update: AvailableUpdate?) {
        terminalViewController?.statusBarView?.setUpdate(update)
    }

    private func openLatestRelease() {
        // Reuse the last-known pill URL, or fall back to a fresh check.
        updateChecker.check { [weak self] result in
            if case .success(let update) = result, let update {
                NSWorkspace.shared.open(update.url)
                self?.applyUpdate(update)
            }
        }
    }

    /// Manual "Check for Updates…" — always runs, reports the outcome.
    @objc private func checkForUpdates(_ sender: Any?) {
        updateChecker.check { [weak self] result in
            switch result {
            case .success(let update):
                self?.applyUpdate(update)
                if update == nil { self?.showUpdateInfo("You're up to date.") }
            case .failure:
                self?.showUpdateInfo("Couldn't check for updates.")
            }
        }
    }

    private func showUpdateInfo(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        if let window = terminalViewController?.view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else { alert.runModal() }
    }
```

Call `startUpdateChecks()` at the end of `applicationDidFinishLaunching`.

> `terminalViewController?.statusBarView` — if the TVC doesn't already expose its `StatusBarView`, add an `internal` accessor (the TVC owns it). Match the existing status-bar access pattern in AppDelegate.

- [ ] **Step 3: Build**

Run: `mise exec -- tuist generate --no-open && xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify live**

Temporarily build with an older `CFBundleShortVersionString` (or after v0.1.7 exists, run the 0.1.6 build): the pill appears ("↑ Update 0.1.7"), clicking opens the release page. Menu **Check for Updates…** reports up-to-date / available / error. Set `check-updates = false` in `~/.config/zetty/config`, reload (⇧⌘,) — no automatic pill (manual menu still works).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/App/StatusBarView.swift App/Sources/App/AppDelegate.swift
git commit -m "feat(app): update pill + Check for Updates menu, launch/periodic checks"
```

---

## Self-Review

**Spec coverage:** GitHub releases source (Task 3) · status-bar pill + menu (Task 4) · launch+periodic+throttle (Task 4) · `check-updates` opt-out (Task 2) · SemVer compare incl. `dev`→no-nag (Task 1) · notify-only/open page (Task 4). ✓

**Placeholder scan:** the two "match the existing layout/access pattern" notes are guidance for adapting to `StatusBarView`/TVC internals not fully quoted here — every code block is complete; the reviewer must slot the pill into the existing right-side layout and expose `statusBarView` if not already. No TBD in logic.

**Type consistency:** `SemVer(_:)` / `SemVer.isNewer(latest:than:)`, `AvailableUpdate(version:url:)`, `UpdateChecker(currentVersion:)`/`check(completion:)`, `StatusBarView.setUpdate(_:)`/`onUpdateClicked`, `AppConfig.checkUpdates` — consistent across tasks.

**Prerequisite:** the repo must be public for the endpoint to work unauthenticated — handled as a separate step (with a secret scan) outside this plan.
