import Foundation

// MARK: - AppearanceMode

/// How Zetty chooses its color scheme.
///
/// - `system`: follow the macOS appearance — use `themeDark` when the OS is
///   dark, `themeLight` when it is light, and switch live when the user toggles.
/// - `dark`: always use `themeDark`.
/// - `light`: always use `themeLight`.
public enum AppearanceMode: String, Sendable, CaseIterable {
    case system
    case dark
    case light
}

// MARK: - GhosttyDirective

/// A raw ghostty config directive to forward verbatim to libghostty, sourced
/// from `ghostty.<key> = <value>` lines in Zetty's config. Order is preserved
/// and duplicate keys are allowed (ghostty's `keybind`/`palette` repeat).
public struct GhosttyDirective: Equatable, Sendable {
    public let key: String
    public let value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

// MARK: - AppConfig

/// User configuration, parsed from a ghostty-style plain-text file
/// (`key = value`, full-line `#` comments). Unknown keys are ignored so the
/// format can grow without breaking older configs.
public struct AppConfig: Equatable, Sendable {

    public var appearance: AppearanceMode
    /// Scheme name used for the dark appearance (matched case-insensitively
    /// against the app's built-in scheme names).
    public var themeDark: String
    /// Scheme name used for the light appearance.
    public var themeLight: String
    /// App used by "Open in Editor" (an app name like "Zed" or a bundle id like
    /// "dev.zed.Zed"). `nil` → the system default app for the file.
    public var editor: String?
    /// When true, panes run inside zmx sessions that survive app quit/relaunch.
    public var preserveSessions: Bool
    /// When true (default), quitting asks for confirmation first; when false
    /// the app quits immediately.
    public var confirmQuit: Bool
    /// Attention sound when an agent needs attention.
    public var notifySound: Bool
    /// Dock badge showing the count of panes needing attention.
    public var notifyBadge: Bool
    /// macOS Notification Center alerts when an agent needs attention and
    /// Zetty is in the background.
    public var notifySystem: Bool
    /// Raw ghostty directives (from `ghostty.<key> = <value>` lines), forwarded
    /// to the terminal unchanged.
    public var ghostty: [GhosttyDirective]

    public static let defaultThemeDark = "Twilight"
    public static let defaultThemeLight = "Daylight"

    public init(
        appearance: AppearanceMode = .system,
        themeDark: String = AppConfig.defaultThemeDark,
        themeLight: String = AppConfig.defaultThemeLight,
        editor: String? = nil,
        preserveSessions: Bool = false,
        confirmQuit: Bool = true,
        notifySound: Bool = true,
        notifyBadge: Bool = true,
        notifySystem: Bool = true,
        ghostty: [GhosttyDirective] = []
    ) {
        self.appearance = appearance
        self.themeDark = themeDark
        self.themeLight = themeLight
        self.editor = editor
        self.preserveSessions = preserveSessions
        self.confirmQuit = confirmQuit
        self.notifySound = notifySound
        self.notifyBadge = notifyBadge
        self.notifySystem = notifySystem
        self.ghostty = ghostty
    }

    // MARK: Parsing

    /// Parses Zetty config text (a superset of ghostty's format).
    ///
    /// Rules: one `key = value` per line; a line whose first non-space character
    /// is `#` is a full-line comment (inline `#` is NOT a comment, so `#`-prefixed
    /// color values survive); blank lines are skipped; keys are case-insensitive;
    /// values are trimmed.
    ///
    /// `appearance`, `theme-dark`, `theme-light`, `editor`, and
    /// `preserve-sessions` are Zetty's own keys. **Every other `key = value`
    /// line is treated as a ghostty directive**
    /// and forwarded verbatim — so a user can paste their existing ghostty config
    /// straight in. Ghostty defines none of the reserved keys, so no collision.
    public static func parse(_ text: String) -> AppConfig {
        var config = AppConfig()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(rawLine).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }   // full-line comments only
            guard let eq = trimmed.firstIndex(of: "=") else { continue }

            let rawKey = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let key = rawKey.lowercased()
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "appearance":
                if let mode = AppearanceMode(rawValue: value.lowercased()) {
                    config.appearance = mode
                }
            case "theme-dark":
                config.themeDark = value
            case "theme-light":
                config.themeLight = value
            case "editor":
                config.editor = value
            case "preserve-sessions":
                config.preserveSessions = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "confirm-quit":
                config.confirmQuit = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "notify-sound":
                config.notifySound = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "notify-badge":
                config.notifyBadge = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "notify-system":
                config.notifySystem = ["true", "yes", "on", "1"].contains(value.lowercased())
            default:
                // Anything else is a pasted ghostty directive → forward verbatim.
                config.ghostty.append(GhosttyDirective(key: rawKey, value: value))
            }
        }
        return config
    }

    // MARK: Rendering

    /// Renders this config back to the documented file format (used when the app
    /// persists a runtime change, e.g. the scheme switcher).
    public func rendered() -> String {
        var out = """
        # Zetty configuration
        # Plain text, one `key = value` per line. A line starting with # is a comment.

        # Appearance mode: system | dark | light
        #   system -> follow the macOS appearance (uses theme-dark or theme-light)
        #   dark   -> always use theme-dark
        #   light  -> always use theme-light
        appearance = \(appearance.rawValue)

        # Color scheme for each appearance.
        # Built-in schemes: Midnight, Nocturne, Frost, Twilight, Ember, Daylight, Paper
        theme-dark  = \(themeDark)
        theme-light = \(themeLight)

        # Keep terminal sessions alive across app quit/relaunch (requires zmx).
        preserve-sessions = \(preserveSessions)

        # Ask for confirmation before quitting (false quits immediately).
        confirm-quit = \(confirmQuit)

        # Agent needs-attention alerts: sound, Dock badge (attention-pane count),
        # and macOS Notification Center (fires only while Zetty is in background).
        notify-sound  = \(notifySound)
        notify-badge  = \(notifyBadge)
        notify-system = \(notifySystem)

        """
        if let editor, !editor.isEmpty {
            out += """
            # App used by Settings → "Open in Editor" (app name or bundle id).
            editor = \(editor)

            """
        }
        out += """
        # Paste any ghostty config lines below — they're forwarded to the terminal
        # as-is (e.g. font-family, font-size, cursor-style, window-padding-x, keybind).

        """
        if !ghostty.isEmpty {
            out += ghostty.map { "\($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"
        }
        return out
    }

    // MARK: Default file

    /// The documented starter config written on first launch.
    public static let defaultFileContents = """
    # Zetty configuration
    # Plain text, one `key = value` per line. Text after # is a comment.

    # Appearance mode: system | dark | light
    #   system -> follow the macOS appearance (uses theme-dark or theme-light)
    #   dark   -> always use theme-dark
    #   light  -> always use theme-light
    appearance = system

    # Color scheme for each appearance.
    # Built-in schemes: Midnight, Nocturne, Frost, Twilight, Ember, Daylight, Paper
    theme-dark  = Twilight
    theme-light = Daylight

    # App used by Settings → "Open in Editor" (an app name like Zed, or a bundle
    # id like dev.zed.Zed). When unset, the system default app for the file opens.
    # editor = Zed

    # Keep terminal sessions alive across app quit/relaunch. Requires zmx
    # (brew install neurosnap/tap/zmx); also toggleable in Settings (⌘,).
    preserve-sessions = false

    # Ask for confirmation before quitting (false quits immediately).
    confirm-quit = true

    # Agent needs-attention alerts: sound, Dock badge (attention-pane count),
    # and macOS Notification Center (fires only while Zetty is in background).
    notify-sound  = true
    notify-badge  = true
    notify-system = true

    # Paste your ghostty config below — any non-Zetty key is forwarded to the
    # terminal verbatim, so an existing ghostty config works as-is. For example:
    #   font-family = JetBrains Mono
    #   font-size = 14
    #   cursor-style = bar
    #   window-padding-x = 8

    """
}
