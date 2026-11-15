import Foundation

/// Pure install/uninstall transforms for Claude Code's `settings.json` hooks.
///
/// Claude hooks are additive (an event maps to an array of matcher-groups), so
/// we append our own group per event and identify it (on reinstall, repair and
/// uninstall) by the hook command referencing our script path. All other hooks
/// are preserved.
public enum ClaudeHookConfig {

    /// (Claude hook event, Zetty status, matcher) for every hook Zetty installs.
    public static let events: [(event: String, status: String, matcher: String?)] = [
        // Present-and-waiting, not busy: a fresh session's id has to be seen
        // before its first prompt (and again after /clear or --resume).
        ("SessionStart", "idle", nil),
        ("UserPromptSubmit", "running", nil),
        // Work that starts without a prompt (after an approval, a subagent or
        // background task waking). They fire per tool call, so the helper
        // stays a quick append and the reducer ignores running-while-running.
        ("PreToolUse", "running", nil),
        ("PostToolUse", "running", nil),
        ("PermissionRequest", "needsAttention", nil),
        // Decisions only: `idle_prompt` (Claude idle ~60 s after a turn) is
        // not "needs you" (Glen, 2026-11-15).
        ("Notification", "needsAttention", "permission_prompt|elicitation_dialog"),
        ("Stop", "idle", nil),
        ("SessionEnd", "ended", nil),
    ]

    public static func command(scriptPath: String, status: String) -> String {
        "\(scriptPath) emit claude \(status)"
    }

    /// Adds Zetty's hooks to a parsed `settings.json` dictionary (idempotent).
    /// An existing Zetty group keeps its place and has its `matcher` brought
    /// in line with `events`; other groups are never touched.
    public static func install(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (event, status, matcher) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            if let index = groups.firstIndex(where: { isOurs($0, scriptPath: scriptPath) }) {
                groups[index]["matcher"] = matcher
            } else {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command(scriptPath: scriptPath, status: status)]]]
                group["matcher"] = matcher
                groups.append(group)
            }
            hooks[event] = groups
        }

        settings["hooks"] = hooks
        return settings
    }

    /// True when Zetty's hooks are installed (any present) but out of date:
    /// an event in `events` has no Zetty group, or our group's matcher
    /// differs. Never true when nothing of ours is installed, so a repair
    /// can't install hooks the user didn't ask for.
    public static func needsRepair(in settings: [String: Any], scriptPath: String) -> Bool {
        guard isInstalled(in: settings, scriptPath: scriptPath),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.contains { event, _, matcher in
            let groups = hooks[event] as? [[String: Any]] ?? []
            guard let ours = groups.first(where: { isOurs($0, scriptPath: scriptPath) }) else { return true }
            return (ours["matcher"] as? String) != matcher
        }
    }

    private static func isOurs(_ group: [String: Any], scriptPath: String) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains(scriptPath) == true
        } == true
    }

    /// Removes Zetty's hooks (any command referencing `scriptPath`), dropping
    /// emptied groups/events, and the `hooks` key if it becomes empty.
    public static func uninstall(from settings: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }

        for (event, _, _) in events {
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

    /// True if any of Zetty's hook commands are present.
    public static func isInstalled(in settings: [String: Any], scriptPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.contains { event, _, _ in
            (hooks[event] as? [[String: Any]])?.contains { isOurs($0, scriptPath: scriptPath) } == true
        }
    }
}
