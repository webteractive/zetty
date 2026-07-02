import Foundation

/// Pure install/uninstall transforms for Claude Code's `settings.json` hooks.
///
/// Claude hooks are additive (an event maps to an array of matcher-groups), so
/// we append our own group per event and identify it on uninstall by the hook
/// command referencing our script path. All other hooks are preserved.
public enum ClaudeHookConfig {

    /// (Claude hook event, quertty status) pairs.
    public static let events: [(event: String, status: String)] = [
        ("UserPromptSubmit", "running"),
        ("Notification", "needsAttention"),
        ("Stop", "idle"),
        ("SessionEnd", "ended"),
    ]

    public static func command(scriptPath: String, status: String) -> String {
        "\(scriptPath) emit claude \(status)"
    }

    /// Adds quertty's hooks to a parsed `settings.json` dictionary (idempotent).
    public static func install(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (event, status) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let alreadyPresent = groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.contains(scriptPath) == true
                } == true
            }
            if !alreadyPresent {
                groups.append(["hooks": [["type": "command", "command": command(scriptPath: scriptPath, status: status)]]])
            }
            hooks[event] = groups
        }

        settings["hooks"] = hooks
        return settings
    }

    /// Removes quertty's hooks (any command referencing `scriptPath`), dropping
    /// emptied groups/events, and the `hooks` key if it becomes empty.
    public static func uninstall(from settings: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }

        for (event, _) in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = groups.compactMap { group -> [String: Any]? in
                guard var inner = group["hooks"] as? [[String: Any]] else { return group }
                inner = inner.filter { ($0["command"] as? String)?.contains(scriptPath) != true }
                if inner.isEmpty { return nil }
                var g = group
                g["hooks"] = inner
                return g
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }

        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return settings
    }

    /// True if any of quertty's hook commands are present.
    public static func isInstalled(in settings: [String: Any], scriptPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.contains { event, _ in
            (hooks[event] as? [[String: Any]])?.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.contains(scriptPath) == true
                } == true
            } == true
        }
    }
}
