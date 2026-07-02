import Foundation

/// Pure install/uninstall transforms for Codex's single `notify` program in
/// `~/.codex/config.toml`.
///
/// Codex allows only one `notify` program, so Zetty **chains**: it points
/// `notify` at our hook and appends the user's original notify array elements,
/// which our hook execs after emitting the event. The original `notify` line is
/// returned as a backup so uninstall can restore it verbatim.
public enum CodexHookConfig {

    public enum InstallResult: Equatable {
        case updated(text: String, backup: String)   // backup = original notify line ("" if none)
        case alreadyInstalled
    }

    public static func install(configText: String, scriptPath: String) -> InstallResult {
        var lines = configText.components(separatedBy: "\n")
        let wrapperPrefix = "notify = [ \"\(scriptPath)\", \"codex\""

        if let i = topLevelNotifyIndex(lines) {
            if lines[i].contains(scriptPath) { return .alreadyInstalled }
            let inner = arrayInner(lines[i])
            let newLine = inner.isEmpty ? "\(wrapperPrefix) ]" : "\(wrapperPrefix), \(inner) ]"
            let backup = lines[i]
            lines[i] = newLine
            return .updated(text: lines.joined(separator: "\n"), backup: backup)
        } else {
            // No notify yet — add one at the top level (before any table header).
            let newLine = "\(wrapperPrefix) ]"
            let insertAt = firstTableHeaderIndex(lines) ?? lines.count
            lines.insert(newLine, at: insertAt)
            return .updated(text: lines.joined(separator: "\n"), backup: "")
        }
    }

    /// Restores the backed-up original notify line (or removes ours if there was
    /// none). No-op if our line isn't present.
    public static func uninstall(configText: String, backup: String, scriptPath: String) -> String {
        var lines = configText.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { isNotifyLine($0) && $0.contains(scriptPath) }) else {
            return configText
        }
        if backup.isEmpty {
            lines.remove(at: i)
        } else {
            lines[i] = backup
        }
        return lines.joined(separator: "\n")
    }

    public static func isInstalled(configText: String, scriptPath: String) -> Bool {
        configText.components(separatedBy: "\n").contains { isNotifyLine($0) && $0.contains(scriptPath) }
    }

    // MARK: - Helpers

    private static func isNotifyLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("notify") && t.contains("=")
    }

    /// The `notify` line index in the top-level region (before the first table).
    private static func topLevelNotifyIndex(_ lines: [String]) -> Int? {
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { return nil }   // reached a table; notify is top-level
            if isNotifyLine(line) { return i }
        }
        return nil
    }

    private static func firstTableHeaderIndex(_ lines: [String]) -> Int? {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
    }

    /// The contents between `[` and `]` on a single-line array assignment.
    private static func arrayInner(_ line: String) -> String {
        guard let l = line.firstIndex(of: "["), let r = line.lastIndex(of: "]"), l < r else { return "" }
        return String(line[line.index(after: l)..<r]).trimmingCharacters(in: .whitespaces)
    }
}
