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

@Test func stoppingTheControlSocketNeverWaitsForItsQueue() {
    // applicationWillTerminate runs on main and calls ControlSocketServer.stop.
    // While a request handler on the socket queue was inside
    // DispatchQueue.main.sync (`zetty accounts --json`, during `zetty quit`),
    // a stop() that did queue.sync left each waiting on the other: the app
    // logged "quit: reason ordinary" and hung with no socket until killed
    // (b0ed43e install on 2026-11-14). stop() hands the teardown to the queue
    // instead of waiting for it.
    let url = repo.appendingPathComponent("App/Sources/App/ControlSocketServer.swift")
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    guard let start = text.range(of: "func stop()"),
          let end = text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex) else {
        Issue.record("ControlSocketServer.stop() not found")
        return
    }
    let body = String(text[start.lowerBound..<end.upperBound])
    for line in codeLines(body) where line.contains(".sync") || line.contains("asyncAndWait") {
        Issue.record("stop() waits for a queue: \(line.trimmingCharacters(in: .whitespaces))")
    }
}

@Test func thePanesFolderNeverComesFromOSC7() {
    // Any program's output can carry OSC 7, and the pane's folder is where a
    // new split's shell starts: `cat` of a file or a remote host picked it
    // for bash and fish panes (security reviews, 2026-11-20 and of
    // 9e58763..cb4df1b). The folder comes from the shell's cwd file or its
    // own process (`CurrentDirectory.choose`), never from OSC 7.
    for file in ["Sources/ZettyCore/Model/CurrentDirectory.swift", "App/Sources/App/TerminalViewController.swift"] {
        let text = (try? String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)) ?? ""
        #expect(!text.isEmpty, "\(file) is missing")
        let offending = codeLines(text).filter { $0.lowercased().contains("osc7") }
        #expect(offending.isEmpty, "\(file) reads OSC 7 into the pane's folder: \(offending)")
    }
}
