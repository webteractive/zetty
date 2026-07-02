import Foundation

/// Pure install/uninstall transforms for Hermes hooks in `~/.hermes/config.yaml`.
///
/// Without a YAML parser we manage a clearly-marked, quertty-owned block. It
/// carries its own top-level `hooks:` key, so it can only be appended when the
/// file has no other top-level `hooks:` — otherwise we'd create a duplicate key.
/// In that case install reports `.conflict` and the app falls back to showing
/// the snippet for manual merge.
public enum HermesHookConfig {

    static let beginMarker = "# >>> Zetty (managed) — do not edit >>>"
    static let endMarker = "# <<< Zetty (managed) <<<"

    /// (Hermes hook event, Zetty status) pairs.
    public static let events: [(event: String, status: String)] = [
        ("on_session_start", "running"),
        ("pre_llm_call", "running"),
        ("pre_approval_request", "needsAttention"),
        ("post_llm_call", "idle"),
        ("on_session_end", "ended"),
    ]

    public enum InstallResult: Equatable {
        case updated(String)
        case conflict(snippet: String)   // a non-Zetty `hooks:` already exists
    }

    public static func managedBlock(scriptPath: String) -> String {
        var lines = [beginMarker, "hooks:"]
        for (event, status) in events {
            lines.append("  \(event):")
            lines.append("    - command: \"\(scriptPath) emit hermes \(status)\"")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    public static func install(configText: String, scriptPath: String) -> InstallResult {
        let stripped = removingManagedBlock(configText)
        let block = managedBlock(scriptPath: scriptPath)

        if hasTopLevelHooks(stripped) {
            return .conflict(snippet: block)
        }
        var base = stripped
        if !base.isEmpty && !base.hasSuffix("\n") { base += "\n" }
        if !base.isEmpty { base += "\n" }
        return .updated(base + block + "\n")
    }

    /// Removes Zetty's managed block (no-op if absent).
    public static func uninstall(configText: String) -> String {
        removingManagedBlock(configText)
    }

    public static func isInstalled(configText: String) -> Bool {
        configText.contains(beginMarker)
    }

    // MARK: - Helpers

    /// Strips the marked region (inclusive) and any trailing blank line it left.
    static func removingManagedBlock(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: beginMarker),
              let end = lines[start...].firstIndex(of: endMarker)
        else { return text }
        var out = Array(lines[..<start])
        // Drop a single trailing blank line before the block, if any.
        if out.last == "" { out.removeLast() }
        out.append(contentsOf: lines[(end + 1)...])
        return out.joined(separator: "\n")
    }

    /// A top-level `hooks:` key (column 0), ignoring our managed block.
    private static func hasTopLevelHooks(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            line == "hooks:" || line.hasPrefix("hooks:") && !line.hasPrefix(" ")
        }
    }
}
