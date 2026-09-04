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

// MARK: - SidebarPosition

/// Which side of the window the project sidebar sits on.
public enum SidebarPosition: String, Sendable, CaseIterable {
    case left
    case right
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
    /// When true (default), relaunch-reattached preserved panes replay their
    /// full zmx scrollback history into the surface before attaching. Only
    /// meaningful when `preserveSessions` is on and zmx is installed.
    public var restoreScrollback: Bool
    /// When true (default), a restart/shutdown/logout quit snapshots preserved
    /// panes' scrollback and tallies running harness sessions, and the next
    /// launch replays + resumes them. Does not gate the login item (that is
    /// system-owned state, registered from Settings).
    public var restartRecovery: Bool
    /// Poll GitHub for newer releases and show an update pill (default true).
    /// Only gates automatic checks; the manual menu item always runs.
    public var checkUpdates: Bool
    /// Auto-hibernate an idle, quiet project after this many seconds (0 = off).
    public var hibernateAfter: TimeInterval
    /// Release the GPU surfaces of a non-active project's panes after this many
    /// seconds out of view, KEEPING their preserved sessions running (0 = off).
    ///
    /// Distinct from `hibernateAfter`, which frees the sessions too. Only ever
    /// applies to session-backed panes — freeing a plain shell's surface would
    /// kill the shell, so those are never touched.
    public var freeBackgroundPanesAfter: TimeInterval
    /// Attention sound when an agent needs attention.
    public var notifySound: Bool
    /// Dock badge showing the count of panes needing attention.
    public var notifyBadge: Bool
    /// macOS Notification Center alerts when an agent needs attention and
    /// Zetty is in the background.
    public var notifySystem: Bool
    /// Which side of the window the project sidebar sits on.
    public var sidebarPosition: SidebarPosition
    /// Directory the permanent Home project is rooted at, as written in the
    /// config (a leading `~` is still unexpanded). `nil` — the default — roots
    /// Home at the account's home directory. Resolve with `resolvedHomePath`.
    public var homePath: String?
    /// Raw ghostty directives (from `ghostty.<key> = <value>` lines), forwarded
    /// to the terminal unchanged.
    /// Command the read-only file viewer pipes a file through for syntax
    /// highlighting; its ANSI output is parsed into attributed text. Empty
    /// disables highlighting (plain text).
    public var viewerHighlightCommand: String
    /// Largest file the viewer will render, in bytes.
    public var viewerMaxBytes: Int
    /// Per-pane file tree preferences (`file-tree-*` keys).
    public var fileTree: FileTreeSettings
    public var ghostty: [GhosttyDirective]
    /// Prefix-key layer: `prefix = <chord>`, `bind = <chord> <command>`, and
    /// `copy-bind = <chord> <command>` lines applied over the tmux-canonical
    /// defaults. (Ghostty's own `keybind` directive is unrelated and still
    /// forwards via `ghostty`.)
    public var keybindings: KeyBindingConfiguration
    /// Zetty keys this build doesn't implement (e.g. written by a newer or
    /// feature-branch build). Recorded for diagnostics and **never** forwarded
    /// to ghostty — see `isReservedButUnsupported`. Not re-emitted by
    /// `rendered()`, so a runtime persist retires the key for good.
    public var unsupportedKeys: [String]

    public static let defaultThemeDark = "Twilight"
    public static let defaultThemeLight = "Daylight"
    public static let defaultViewerHighlightCommand = "bat --style=plain --color=always --paging=never"
    public static let defaultViewerMaxBytes = 2_097_152

    /// Zetty keys that no longer (or don't yet) exist in this build but must
    /// still never reach ghostty. Add retired keys here rather than deleting
    /// their `case` outright.
    public static let retiredReservedKeys: Set<String> = [
        "confirm-quit",   // red close now hands the app off to the menu bar
        "notify-poke",    // agent coordination board (feature branch)
    ]

    /// True when `key` belongs to Zetty rather than ghostty, even though this
    /// build has no `case` for it.
    ///
    /// Forwarding such a key is not a harmless no-op: libghostty rejects its
    /// ENTIRE config when any key produces a diagnostic, which silently drops
    /// every custom directive — including the per-surface `command` behind
    /// session preservation — so panes launch plain shells and preserved
    /// sessions are stranded.
    ///
    /// `zetty-` is the namespace for Zetty's own keys and the one NEW keys
    /// should use: anything under it is ours by construction, so a key written
    /// by a newer build is swallowed without anyone having to remember to
    /// register it here. `notify-` is grandfathered — those keys predate the
    /// convention and stay unprefixed for compatibility. Ghostty defines no key
    /// in either namespace, so there is no collision.
    public static func isReservedButUnsupported(_ key: String) -> Bool {
        retiredReservedKeys.contains(key)
            || key.hasPrefix("notify-")
            || key.hasPrefix("zetty-")
    }

    public init(
        appearance: AppearanceMode = .system,
        themeDark: String = AppConfig.defaultThemeDark,
        themeLight: String = AppConfig.defaultThemeLight,
        editor: String? = nil,
        preserveSessions: Bool = false,
        restoreScrollback: Bool = true,
        restartRecovery: Bool = true,
        checkUpdates: Bool = true,
        hibernateAfter: TimeInterval = 0,
        freeBackgroundPanesAfter: TimeInterval = 0,
        notifySound: Bool = true,
        notifyBadge: Bool = true,
        notifySystem: Bool = true,
        sidebarPosition: SidebarPosition = .left,
        homePath: String? = nil,
        viewerHighlightCommand: String = AppConfig.defaultViewerHighlightCommand,
        viewerMaxBytes: Int = AppConfig.defaultViewerMaxBytes,
        fileTree: FileTreeSettings = FileTreeSettings(),
        ghostty: [GhosttyDirective] = [],
        keybindings: KeyBindingConfiguration = KeyBindingConfiguration(),
        unsupportedKeys: [String] = []
    ) {
        self.appearance = appearance
        self.themeDark = themeDark
        self.themeLight = themeLight
        self.editor = editor
        self.preserveSessions = preserveSessions
        self.restoreScrollback = restoreScrollback
        self.restartRecovery = restartRecovery
        self.checkUpdates = checkUpdates
        self.hibernateAfter = hibernateAfter
        self.freeBackgroundPanesAfter = freeBackgroundPanesAfter
        self.notifySound = notifySound
        self.notifyBadge = notifyBadge
        self.notifySystem = notifySystem
        self.sidebarPosition = sidebarPosition
        self.homePath = homePath
        self.viewerHighlightCommand = viewerHighlightCommand
        self.viewerMaxBytes = viewerMaxBytes
        self.fileTree = fileTree
        self.ghostty = ghostty
        self.keybindings = keybindings
        self.unsupportedKeys = unsupportedKeys
    }

    // MARK: Parsing

    /// Parses Zetty config text (a superset of ghostty's format).
    ///
    /// Rules: one `key = value` per line; a line whose first non-space character
    /// is `#` is a full-line comment (inline `#` is NOT a comment, so `#`-prefixed
    /// color values survive); blank lines are skipped; keys are case-insensitive;
    /// values are trimmed.
    ///
    /// `appearance`, `theme-dark`, `theme-light`, `editor`,
    /// `preserve-sessions`, and `restore-scrollback` are Zetty's own keys.
    /// **Every other `key = value` line is treated as a ghostty directive**
    /// and forwarded verbatim — so a user can paste their existing ghostty config
    /// straight in. Ghostty defines none of the reserved keys, so no collision.
    /// Parses a duration for `hibernate-after`: "90"→90s, "60m"→3600, "2h"→7200;
    /// "off"/"0"/blank/invalid → 0.
    static func parseDuration(_ raw: String) -> TimeInterval {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty || s == "off" || s == "false" { return 0 }
        let unit = s.last
        let numberPart = (unit == "m" || unit == "h" || unit == "s") ? String(s.dropLast()) : s
        guard let value = Double(numberPart), value >= 0 else { return 0 }
        switch unit {
        case "h": return value * 3600
        case "m": return value * 60
        default:  return value
        }
    }

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
            case "restore-scrollback":
                config.restoreScrollback = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "check-updates":
                config.checkUpdates = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "hibernate-after":
                config.hibernateAfter = AppConfig.parseDuration(value)
            case "free-background-panes-after":
                config.freeBackgroundPanesAfter = AppConfig.parseDuration(value)
            case "notify-sound":
                config.notifySound = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "notify-badge":
                config.notifyBadge = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "notify-system":
                config.notifySystem = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "sidebar-position":
                if let position = SidebarPosition(rawValue: value.lowercased()) {
                    config.sidebarPosition = position
                }
            case "viewer-highlight-command":
                // `off`/`none`/`false` disables highlighting. An empty VALUE
                // can't reach here — the parser skips empty values — so these
                // words are the documented way to turn it off.
                let lowered = value.lowercased()
                config.viewerHighlightCommand = ["off", "none", "false"].contains(lowered) ? "" : value
            case "viewer-max-bytes":
                if let bytes = Int(value), bytes > 0 { config.viewerMaxBytes = bytes }
            // New keys take the `zetty-` prefix: `isReservedButUnsupported`
            // swallows the whole namespace, so a future `zetty-*` key can never
            // leak to ghostty and drop the config.
            case "zetty-home-path":
                // `off`/`none`/`default`/`~` all mean the account's home
                // directory, i.e. no override. An empty VALUE can't reach here
                // (the parser skips empty values), so these are the documented
                // way back to the default.
                let lowered = value.lowercased()
                config.homePath = ["off", "none", "default", "~"].contains(lowered) ? nil : value
            case "zetty-restart-recovery":
                config.restartRecovery = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "zetty-file-tree-show-hidden":
                config.fileTree.showHidden = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "zetty-file-tree-respect-gitignore":
                config.fileTree.respectGitignore = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "zetty-file-tree-ignore":
                config.fileTree.extraIgnores = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "zetty-file-tree-width":
                if let width = Double(value), width > 0 { config.fileTree.width = width }
            case "prefix":
                config.keybindings.applyPrefix(value)
            case "bind":
                config.keybindings.applyBind(value, toCopyTable: false)
            case "copy-bind":
                config.keybindings.applyBind(value, toCopyTable: true)
            default:
                // A Zetty key this build lacks must be swallowed, NOT forwarded:
                // one key ghostty rejects discards the whole config (including
                // the session-preservation `command`).
                if AppConfig.isReservedButUnsupported(key) {
                    config.unsupportedKeys.append(key)
                } else {
                    // Anything else is a pasted ghostty directive → forward verbatim.
                    config.ghostty.append(GhosttyDirective(key: rawKey, value: value))
                }
            }
        }
        return config
    }

    // MARK: Home path

    /// The directory the Home project should be rooted at: `homePath` with a
    /// leading `~` expanded against `defaultHome` and a trailing slash trimmed,
    /// or `defaultHome` itself when there is no override.
    ///
    /// Pure — ZettyCore never touches the filesystem, so the caller is the one
    /// that checks the directory exists (and falls back to `defaultHome` when it
    /// doesn't; Home must always open somewhere).
    ///
    /// `~` is expanded by hand rather than through `expandingTildeInPath`, which
    /// also rewrites `~someone` into another account's home — a directory
    /// literally named `~backup` is a real path, not a home reference.
    public func resolvedHomePath(defaultHome: String) -> String {
        guard let raw = homePath?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return defaultHome
        }
        var path = raw
        if path == "~" {
            path = defaultHome
        } else if path.hasPrefix("~/") {
            path = defaultHome + String(path.dropFirst(1))
        }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The value to WRITE for `zetty-home-path` when the user picks `path`:
    /// tilde-abbreviated so the config stays readable and portable between
    /// machines, or `nil` when the pick is the home directory itself (which is
    /// the default, so the key is dropped rather than pinned).
    ///
    /// The inverse of `resolvedHomePath(defaultHome:)`.
    public static func homePathValue(for path: String, defaultHome: String) -> String? {
        var trimmed = path.trimmingCharacters(in: .whitespaces)
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, trimmed != defaultHome else { return nil }
        guard trimmed.hasPrefix(defaultHome + "/") else { return trimmed }
        return "~" + trimmed.dropFirst(defaultHome.count)
    }

    // MARK: Ghostty directive helpers

    /// The effective value of a ghostty directive — the **last** occurrence of
    /// `key` (case-insensitive), matching ghostty's last-wins semantics for
    /// scalar keys. `nil` when the directive is absent.
    public func ghosttyValue(_ key: String) -> String? {
        let needle = key.lowercased()
        return ghostty.last { $0.key.lowercased() == needle }?.value
    }

    /// Returns a copy with the `key` directive set to `value`: the last
    /// occurrence is replaced in place (earlier duplicates are dropped, so the
    /// result has one occurrence and it still wins), or the directive is
    /// appended when absent. A `nil` value removes every occurrence — the
    /// terminal falls back to its own default.
    public func settingGhostty(key: String, value: String?) -> AppConfig {
        let needle = key.lowercased()
        var config = self
        guard let value else {
            config.ghostty.removeAll { $0.key.lowercased() == needle }
            return config
        }
        guard let last = config.ghostty.lastIndex(where: { $0.key.lowercased() == needle }) else {
            config.ghostty.append(GhosttyDirective(key: key, value: value))
            return config
        }
        config.ghostty = config.ghostty.enumerated().compactMap { index, directive in
            guard directive.key.lowercased() == needle else { return directive }
            return index == last ? GhosttyDirective(key: directive.key, value: value) : nil
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
        # Built-in schemes — dark: Midnight, Nocturne, Frost, Twilight, Ember, Velvet,
        #   Eclipse, Rosewood, Neon, Ukiyo · light: Daylight, Paper, Glacier, Dawn,
        #   Latte, Porcelain, Harvest, Citrus, Daybreak, Sakura
        theme-dark  = \(themeDark)
        theme-light = \(themeLight)

        # Keep terminal sessions alive across app quit/relaunch (requires zmx).
        preserve-sessions = \(preserveSessions)

        # Replay preserved panes' scrollback history when relaunch reattaches
        # them (only meaningful with preserve-sessions = true).
        restore-scrollback = \(restoreScrollback)

        # After a macOS restart, shutdown or logout, replay each preserved pane's
        # last screen and resume the Claude/Codex session it was running.
        zetty-restart-recovery = \(restartRecovery)

        # Check GitHub for newer Zetty releases and show an update pill.
        check-updates = \(checkUpdates)

        # Auto-hibernate a project after it's idle and quiet (0/off = disabled,
        # e.g. 60m or 2h). Frees its sessions/processes; waking spawns fresh shells.
        hibernate-after = \(hibernateAfter == 0 ? "off" : String(Int(hibernateAfter)))

        # Release a background project's GPU surfaces after it's been out of view
        # this long, while its shells keep running in their preserved sessions
        # (0/off = disabled, e.g. 5m). Reclaims ~37MB per pane; the pane
        # re-attaches with its scrollback when you switch back. Only affects
        # panes that have a preserved session — plain shells are never freed.
        free-background-panes-after = \(freeBackgroundPanesAfter == 0 ? "off" : String(Int(freeBackgroundPanesAfter)))

        # Agent needs-attention alerts: sound, Dock badge (attention-pane count),
        # and macOS Notification Center (fires only while Zetty is in background).
        notify-sound  = \(notifySound)
        notify-badge  = \(notifyBadge)
        notify-system = \(notifySystem)

        # Which side of the window the project sidebar sits on: left | right
        sidebar-position = \(sidebarPosition.rawValue)

        # Directory the permanent Home project is rooted at (new tabs and panes
        # open here). Defaults to your home directory; `off` or `~` restores it.
        \(homePath.map { "zetty-home-path = \($0)" } ?? "# zetty-home-path = ~/Projects")

        # Syntax highlighting for the read-only file viewer: the file is piped
        # through this command and its ANSI colors are rendered. `off` disables
        # it. A missing or failing command falls back to plain text.
        viewer-highlight-command = \(viewerHighlightCommand.isEmpty ? "off" : viewerHighlightCommand)

        # Largest file the viewer will render, in bytes.
        viewer-max-bytes = \(viewerMaxBytes)

        # Per-pane file tree (toggle from the pane gutter, or Ctrl+B e).
        # Defaults show the raw filesystem; filtering is opt-in.
        zetty-file-tree-show-hidden = \(fileTree.showHidden)
        zetty-file-tree-respect-gitignore = \(fileTree.respectGitignore)
        zetty-file-tree-ignore = \(fileTree.extraIgnores.joined(separator: ", "))
        zetty-file-tree-width = \(Int(fileTree.width))

        """
        if let editor, !editor.isEmpty {
            out += """
            # App used by Settings → "Open in Editor" (app name or bundle id).
            editor = \(editor)

            """
        }
        if !keybindings.sourceLines.isEmpty {
            out += """
            # Prefix-key layer (tmux-style). `prefix = <chord>`, then repeated
            # `bind = <chord> <command>` / `copy-bind = <chord> <command>` lines.
            \(keybindings.sourceLines.joined(separator: "\n"))

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
    # Built-in schemes — dark: Midnight, Nocturne, Frost, Twilight, Ember, Velvet,
    #   Eclipse, Rosewood, Neon, Ukiyo · light: Daylight, Paper, Glacier, Dawn,
    #   Latte, Porcelain, Harvest, Citrus, Daybreak, Sakura
    theme-dark  = Twilight
    theme-light = Daylight

    # App used by Settings → "Open in Editor" (an app name like Zed, or a bundle
    # id like dev.zed.Zed). When unset, the system default app for the file opens.
    # editor = Zed

    # Keep terminal sessions alive across app quit/relaunch. Requires zmx
    # (brew install neurosnap/tap/zmx); also toggleable in Settings (⌘,).
    preserve-sessions = false

    # Replay preserved panes' scrollback history when relaunch reattaches
    # them (only meaningful with preserve-sessions = true).
    restore-scrollback = true

    # Agent needs-attention alerts: sound, Dock badge (attention-pane count),
    # and macOS Notification Center (fires only while Zetty is in background).
    notify-sound  = true
    notify-badge  = true
    notify-system = true

    # Which side of the window the project sidebar sits on: left | right
    sidebar-position = left

    # Directory the permanent Home project is rooted at — its new tabs and panes
    # open here. Defaults to your home directory; `off` or `~` restores that.
    # zetty-home-path = ~/Projects

    # tmux-style prefix key layer. Ctrl+B then a key: % " split · h/j/k/l or
    # arrows focus panes · o cycle · x close · z zoom · c new tab · n/p/1-9
    # tabs · , rename · [ copy mode (vi keys) · ] paste. Remap with:
    #   prefix = ctrl+b
    #   bind = <chord> <command>        (e.g. bind = s split-vertical)
    #   copy-bind = <chord> <command>   (e.g. copy-bind = n copy-cursor-down)

    # Paste your ghostty config below — any non-Zetty key is forwarded to the
    # terminal verbatim, so an existing ghostty config works as-is. For example:
    #   font-family = JetBrains Mono
    #   font-size = 14
    #   cursor-style = bar
    #   window-padding-x = 8

    """
}
