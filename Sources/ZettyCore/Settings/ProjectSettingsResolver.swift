import Foundation

/// What actually applies to a project right now — the precedence chain
/// (project private override → global config → built-in default) collapsed
/// into concrete values. The app layer asks this one place instead of
/// re-implementing precedence at every seam.
public struct ResolvedProjectSettings: Equatable, Sendable {
    public var name: String
    public var colorID: String?
    public var icon: String?
    /// Per-project appearance/theme overrides, mirroring the global model
    /// (appearance axis + a scheme per axis); nil fields → the global keys.
    public var appearanceOverride: String?
    public var themeDarkOverride: String?
    public var themeLightOverride: String?
    public var preserveSessions: Bool
    public var notifySound: Bool
    public var notifyBadge: Bool
    public var notifySystem: Bool
    /// Env vars for this project's panes (empty when unset — values never
    /// come from the repo file).
    public var env: [String: String]
    /// This project's default agent account id; nil = the agent's own default
    /// login. Resolved here so a clone inherits its source's account along with
    /// the rest of its settings.
    public var accountID: String?
}

public enum ProjectSettingsResolver {

    public static func resolve(
        _ settings: ProjectSettings?,
        fallbackName: String,
        global: AppConfig
    ) -> ResolvedProjectSettings {
        let trimmedName = settings?.name?.trimmingCharacters(in: .whitespaces)
        let name = (trimmedName?.isEmpty == false ? trimmedName : nil) ?? fallbackName

        // Tri-state notifications: false suppresses all channels, true forces
        // all, nil follows each global channel individually.
        let notifySound: Bool
        let notifyBadge: Bool
        let notifySystem: Bool
        switch settings?.notificationsOverride {
        case .some(let forced):
            notifySound = forced
            notifyBadge = forced
            notifySystem = forced
        case .none:
            notifySound = global.notifySound
            notifyBadge = global.notifyBadge
            notifySystem = global.notifySystem
        }

        return ResolvedProjectSettings(
            name: name,
            colorID: settings?.color,
            icon: settings?.icon,
            appearanceOverride: settings?.appearanceOverride,
            themeDarkOverride: settings?.themeDarkOverride,
            themeLightOverride: settings?.themeLightOverride,
            preserveSessions: settings?.preserveSessionsOverride ?? global.preserveSessions,
            notifySound: notifySound,
            notifyBadge: notifyBadge,
            notifySystem: notifySystem,
            env: settings?.env ?? [:],
            accountID: settings?.accountID
        )
    }
}
