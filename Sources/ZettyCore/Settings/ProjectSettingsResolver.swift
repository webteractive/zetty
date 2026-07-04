import Foundation

/// What actually applies to a project right now — the precedence chain
/// (project private override → global config → built-in default) collapsed
/// into concrete values. The app layer asks this one place instead of
/// re-implementing precedence at every seam.
public struct ResolvedProjectSettings: Equatable, Sendable {
    public var name: String
    public var colorID: String?
    public var icon: String?
    public var preserveSessions: Bool
    public var notifySound: Bool
    public var notifyBadge: Bool
    public var notifySystem: Bool
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
            preserveSessions: settings?.preserveSessionsOverride ?? global.preserveSessions,
            notifySound: notifySound,
            notifyBadge: notifyBadge,
            notifySystem: notifySystem
        )
    }
}
