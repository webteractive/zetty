import Foundation

/// Per-project overrides of global defaults plus project-only identity.
/// Every field is optional; `nil` = "follow global" (for overrides) or
/// "feature off" (for project-only fields). Decoding is tolerant so fields
/// added later never break older files.
public struct ProjectSettings: Codable, Sendable, Equatable {
    /// Display-name override; nil/empty → the folder name.
    public var name: String?
    /// Curated palette id (see the app layer's project palette); nil → no color.
    public var color: String?
    /// SF Symbol name for the row glyph; nil → the default diamond.
    public var icon: String?
    /// Per-project appearance axis, mirroring the global `appearance` key
    /// ("system" / "dark" / "light"); nil → follow the global appearance.
    public var appearanceOverride: String?
    /// Scheme displayName used while this project is active AND the effective
    /// appearance is dark; nil → the global `theme-dark`. Validated app-side.
    public var themeDarkOverride: String?
    /// Light-axis counterpart of `themeDarkOverride` (global `theme-light`).
    public var themeLightOverride: String?
    /// Tri-state override of the global `preserve-sessions` (nil = follow).
    public var preserveSessionsOverride: Bool?
    /// Tri-state notifications override: nil = follow the global
    /// notify-sound/badge/system keys; false = suppress all three for this
    /// project; true = force all three. The in-app bell is never gated.
    public var notificationsOverride: Bool?
    /// Environment variables injected into this project's panes. Values live
    /// ONLY here (the private per-user store) — the repo file carries names
    /// at most (`ProjectFile.envNames`). New panes/sessions only.
    public var env: [String: String]?
    /// Per-project spawnable agents (Agents tab). nil/empty → feature off.
    /// Presence of an entry = that agent is enabled; `command` is its launch
    /// command. Stored in the private store only.
    public var agents: [ProjectAgent]?
    /// Master switch for the new-pane agent chooser. nil (default) or true →
    /// the modal shows when ≥1 agent is enabled; false → never prompt (a direct
    /// off switch that keeps the enabled-agent list intact).
    public var promptAgentOnNewPane: Bool?
    /// Tri-state override of global auto-hibernation: nil = follow global,
    /// false = never auto-hibernate this project (manual hibernate still works).
    public var autoHibernate: Bool?
    /// Broadcast (synchronized input) scope for this project, as a
    /// `BroadcastScope` code ("tab"/"project"/"agents"/"workspace"); nil = Off.
    /// Broadcast is per-project and Off by default. Edited live (menu/cycle) or
    /// in Project Settings.
    public var broadcastScope: String?

    public init(
        name: String? = nil,
        color: String? = nil,
        icon: String? = nil,
        appearanceOverride: String? = nil,
        themeDarkOverride: String? = nil,
        themeLightOverride: String? = nil,
        preserveSessionsOverride: Bool? = nil,
        notificationsOverride: Bool? = nil,
        env: [String: String]? = nil,
        agents: [ProjectAgent]? = nil,
        promptAgentOnNewPane: Bool? = nil,
        autoHibernate: Bool? = nil,
        broadcastScope: String? = nil
    ) {
        self.name = name
        self.color = color
        self.icon = icon
        self.appearanceOverride = appearanceOverride
        self.themeDarkOverride = themeDarkOverride
        self.themeLightOverride = themeLightOverride
        self.preserveSessionsOverride = preserveSessionsOverride
        self.notificationsOverride = notificationsOverride
        self.env = env
        self.agents = agents
        self.promptAgentOnNewPane = promptAgentOnNewPane
        self.autoHibernate = autoHibernate
        self.broadcastScope = broadcastScope
    }

    /// True when every field is nil — the store drops such entries.
    public var isEmpty: Bool { self == ProjectSettings() }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        appearanceOverride = try c.decodeIfPresent(String.self, forKey: .appearanceOverride)
        themeDarkOverride = try c.decodeIfPresent(String.self, forKey: .themeDarkOverride)
        themeLightOverride = try c.decodeIfPresent(String.self, forKey: .themeLightOverride)
        preserveSessionsOverride = try c.decodeIfPresent(Bool.self, forKey: .preserveSessionsOverride)
        notificationsOverride = try c.decodeIfPresent(Bool.self, forKey: .notificationsOverride)
        env = try c.decodeIfPresent([String: String].self, forKey: .env)
        agents = try c.decodeIfPresent([ProjectAgent].self, forKey: .agents)
        promptAgentOnNewPane = try c.decodeIfPresent(Bool.self, forKey: .promptAgentOnNewPane)
        autoHibernate = try c.decodeIfPresent(Bool.self, forKey: .autoHibernate)
        broadcastScope = try c.decodeIfPresent(String.self, forKey: .broadcastScope)
    }
}

/// The on-disk shape of `project-settings.json`: settings keyed by the
/// project's canonical absolute rootPath (survives remove-and-re-add, the
/// durable identity a user thinks in — see the design doc's storage section).
public struct ProjectSettingsFile: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var settings: [String: ProjectSettings]

    public init(schemaVersion: Int = 1, settings: [String: ProjectSettings] = [:]) {
        self.schemaVersion = schemaVersion
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        settings = try c.decodeIfPresent([String: ProjectSettings].self, forKey: .settings) ?? [:]
    }

    public func settings(for rootPath: String) -> ProjectSettings? {
        settings[ProjectSettingsStore.canonicalKey(rootPath)]
    }

    /// Stores (or, when `newSettings.isEmpty`, removes) a project's entry.
    public mutating func set(_ newSettings: ProjectSettings, for rootPath: String) {
        let key = ProjectSettingsStore.canonicalKey(rootPath)
        if newSettings.isEmpty {
            settings.removeValue(forKey: key)
        } else {
            settings[key] = newSettings
        }
    }

    /// True when at least one project forces preserve-sessions ON — the
    /// session-command provider must then be installed even if the global
    /// toggle is off.
    public var anyPreserveOverrideOn: Bool {
        settings.values.contains { $0.preserveSessionsOverride == true }
    }
}
