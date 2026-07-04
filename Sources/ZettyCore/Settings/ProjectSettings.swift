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
    /// Tri-state override of the global `preserve-sessions` (nil = follow).
    public var preserveSessionsOverride: Bool?
    /// Tri-state notifications override: nil = follow the global
    /// notify-sound/badge/system keys; false = suppress all three for this
    /// project; true = force all three. The in-app bell is never gated.
    public var notificationsOverride: Bool?

    public init(
        name: String? = nil,
        color: String? = nil,
        icon: String? = nil,
        preserveSessionsOverride: Bool? = nil,
        notificationsOverride: Bool? = nil
    ) {
        self.name = name
        self.color = color
        self.icon = icon
        self.preserveSessionsOverride = preserveSessionsOverride
        self.notificationsOverride = notificationsOverride
    }

    /// True when every field is nil — the store drops such entries.
    public var isEmpty: Bool { self == ProjectSettings() }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        preserveSessionsOverride = try c.decodeIfPresent(Bool.self, forKey: .preserveSessionsOverride)
        notificationsOverride = try c.decodeIfPresent(Bool.self, forKey: .notificationsOverride)
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
