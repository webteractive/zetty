import Foundation
import Testing

// Source-level guards for bug classes that shipped once and must not again.
// Each reads the repository's own files, so a new occurrence fails `swift
// test` (and so every release, which requires it) with the reason attached.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // ZettyCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // repo root

private func sources(under folders: [String], extensions: Set<String>) -> [(path: String, text: String)] {
    var found: [(String, String)] = []
    for folder in folders {
        let root = repo.appendingPathComponent(folder)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in walker where extensions.contains(url.pathExtension) {
            guard !url.lastPathComponent.hasSuffix("_test.go"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            found.append((String(url.path.dropFirst(repo.path.count + 1)), text))
        }
    }
    return found
}

/// Code lines only: a mention in a comment is not a call.
private func codeLines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter {
        let trimmed = $0.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") && !trimmed.hasPrefix("*")
    }
}

@Test func theProcessEnvironmentChangesOnlyBeforeTheFirstPane() {
    // libghostty copies `environ` once in ghostty_init and reads that copy for
    // every later pane; a setenv/unsetenv afterwards crashed the laptop in
    // ghostty_surface_new (c16e7db, surfaces-and-memory.md). These are the
    // places allowed to change it, each before the first pane or in the CLI
    // process. A new one needs to prove the same, then be added here.
    let allowed: [String: Int] = [
        "App/Sources/App/main.swift": 1,                      // TERMINFO_DIRS, before NSApplication
        "App/Sources/App/AppDelegate.swift": 1,               // ZETTY, before the first TerminalController
        "App/Sources/App/ModInstaller.swift": 1,              // applyEnvironment's first call only
        "Sources/ZettyCore/Accounts/LaunchEnvironment.swift": 1, // clearInherited, from main.swift
        "Sources/ZettyCore/CLI/ControlCLI.swift": 2,          // the CLI process, right before exec
        "Bridge/tailnet/bridge.go": 3,                        // zt_prepare_env, from main.swift
    ]
    let pattern = try! NSRegularExpression(
        pattern: #"\b(setenv|unsetenv|putenv)\(|os\.Setenv\(|envknob\.Setenv\(|envknob\.SetNoLogsNoSupport\("#)
    var counts: [String: Int] = [:]
    for (path, text) in sources(under: ["App/Sources", "Sources", "Bridge"], extensions: ["swift", "go"]) {
        for line in codeLines(text) {
            let range = NSRange(line.startIndex..., in: line)
            counts[path, default: 0] += pattern.numberOfMatches(in: line, range: range)
        }
    }
    counts = counts.filter { $0.value > 0 }
    #expect(counts == allowed, "process-environment changes moved: \(counts)")
}

@Test func zmxIsNeverListedWithShort() {
    // zmx 1.0's `list --short` leaves out every session of another zmx
    // version; a teardown that listed with it freed live sessions' surfaces
    // (0419953 review). List with the full `list` and parse names from it.
    for (path, text) in sources(under: ["App/Sources", "Sources"], extensions: ["swift"]) {
        for line in codeLines(text) where line.contains("\"--short\"") && line.contains("\"list\"") {
            Issue.record("\(path): \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
}
