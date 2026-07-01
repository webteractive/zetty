import AppKit
import GhosttyTerminal

// MARK: - Theme
//
// The single source of truth for quertty's visual design, translated from the
// Claude Design handoff `quertty.dc.html`
// (project def4312f-4b6c-41d2-ae44-98d0d130c35b).
//
// RULES (see DESIGN.md):
//   • Never hardcode a color in a view. Read it from `QTheme.current`.
//   • All terminal / label / tab / status text uses `QTheme.monoFont`; only
//     prose and system chrome use the system font.
//   • Active / selected states use `accent` with a soft glow, never a heavy fill.
//   • Adding a scheme means filling EVERY token below — no partial schemes.

/// The selectable color schemes carried over verbatim from the handoff's
/// `schemes` map. `midnight` is the default.
enum QColorScheme: String, CaseIterable {
    case midnight, nocturne, frost, twilight, ember, daylight, paper

    var displayName: String {
        switch self {
        case .midnight: return "Midnight"
        case .nocturne: return "Nocturne"
        case .frost:    return "Frost"
        case .twilight: return "Twilight"
        case .ember:    return "Ember"
        case .daylight: return "Daylight"
        case .paper:    return "Paper"
        }
    }

    /// Case-insensitive lookup by display name or raw value (used to resolve
    /// scheme names from the config file). Returns `nil` for unknown names.
    static func named(_ name: String) -> QColorScheme? {
        let key = name.lowercased()
        return allCases.first { $0.rawValue == key || $0.displayName.lowercased() == key }
    }
}

/// A fully-specified palette. Values are hex strings WITHOUT a leading `#`
/// (ghostty's config parser and our `NSColor` helper both accept that form),
/// so the same token feeds both the AppKit chrome and the libghostty terminal.
struct QTheme {

    // Design tokens (mirror the CSS custom properties in quertty.dc.html).
    let acc: String       // accent — focus / active / brand
    let bg0: String       // deepest surface — sidebar, tab bar, status bar
    let bg1: String       // base surface — window, main area, terminal, panes
    let bg2: String       // elevated — search fields, hover
    let bg3: String       // highest — pinned rows, kbd chips, selection fill
    let bord: String      // hairline borders / dividers
    let fg: String        // primary text
    let fg2: String       // secondary text
    let fg3: String       // tertiary / dim text, idle status
    let green: String     // running / ok
    let blue: String      // paths / links
    let purple: String    // git / branch
    let yellow: String    // attention / deploy
    let red: String       // error
    let tfg: String        // terminal foreground
    let tdim: String       // terminal dim / prompt punctuation
    let isDark: Bool

    // MARK: Active scheme

    /// The active scheme. Assigning it swaps `current`.
    static var scheme: QColorScheme = .midnight {
        didSet { current = QTheme.palette(for: scheme) }
    }

    /// The palette for the active scheme. Views read tokens from here.
    private(set) static var current: QTheme = QTheme.palette(for: .midnight)

    // MARK: NSColor accessors

    var accentColor: NSColor { QTheme.color(acc) }
    var bg0Color: NSColor    { QTheme.color(bg0) }
    var bg1Color: NSColor    { QTheme.color(bg1) }
    var bg2Color: NSColor    { QTheme.color(bg2) }
    var bg3Color: NSColor    { QTheme.color(bg3) }
    var borderColor: NSColor { QTheme.color(bord) }
    var fgColor: NSColor     { QTheme.color(fg) }
    var fg2Color: NSColor    { QTheme.color(fg2) }
    var fg3Color: NSColor    { QTheme.color(fg3) }
    var greenColor: NSColor  { QTheme.color(green) }
    var yellowColor: NSColor { QTheme.color(yellow) }
    var purpleColor: NSColor { QTheme.color(purple) }

    /// The AppKit appearance that matches this scheme, so native chrome
    /// (menus, scrollers, the titlebar) tracks the palette.
    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    // MARK: Fonts

    /// JetBrains Mono when installed (the handoff's font), else the system
    /// monospaced face. Used for terminal-adjacent UI: tabs, sidebar tree,
    /// status bar, kbd chips.
    static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let jb = NSFont(name: monoPostScriptName(for: weight), size: size) {
            return jb
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func monoPostScriptName(for weight: NSFont.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "JetBrainsMono-Bold"
        case .semibold:             return "JetBrainsMono-SemiBold"
        case .medium:               return "JetBrainsMono-Medium"
        default:                    return "JetBrainsMono-Regular"
        }
    }

    // MARK: Terminal theme

    /// Builds a libghostty `TerminalTheme` from this palette so the terminal
    /// surface matches the app chrome. Both light and dark slots carry the same
    /// scheme, so the terminal shows our colors regardless of OS appearance.
    func terminalTheme() -> TerminalTheme {
        let config = TerminalConfiguration { b in
            b.withFontFamily("JetBrains Mono")
            b.withBackground(bg1)
            b.withForeground(tfg)
            b.withCursorColor(acc)
            b.withCursorText(bg1)
            b.withSelectionBackground(bg3)
            b.withSelectionForeground(fg)
            // 16-color ANSI palette mapped from the scheme's semantic tokens.
            let normal  = [bg3, red, green, yellow, blue, purple, acc, fg2]
            let bright  = [fg3, red, green, yellow, blue, purple, acc, fg]
            for (i, c) in normal.enumerated()  { b.withPalette(i,     color: "#\(c)") }
            for (i, c) in bright.enumerated()  { b.withPalette(i + 8, color: "#\(c)") }
        }
        return TerminalTheme(light: config, dark: config)
    }

    // MARK: Palettes (from quertty.dc.html `schemes`)

    static func palette(for scheme: QColorScheme) -> QTheme {
        switch scheme {
        case .midnight:
            return QTheme(acc: "5eead4", bg0: "09090c", bg1: "0b0b0f", bg2: "131319", bg3: "1a1a22",
                          bord: "1f1f27", fg: "e6e6ea", fg2: "a7a7b2", fg3: "6a6a75",
                          green: "7ee787", blue: "7c9cff", purple: "d2a8ff", yellow: "e3b341", red: "ff7b72",
                          tfg: "c9d1d9", tdim: "6e7681", isDark: true)
        case .nocturne:
            return QTheme(acc: "bd93f9", bg0: "191a21", bg1: "282a36", bg2: "21222c", bg3: "343746",
                          bord: "343746", fg: "f8f8f2", fg2: "c3c5d6", fg3: "6272a4",
                          green: "50fa7b", blue: "8be9fd", purple: "ff79c6", yellow: "f1fa8c", red: "ff5555",
                          tfg: "f8f8f2", tdim: "6272a4", isDark: true)
        case .frost:
            return QTheme(acc: "88c0d0", bg0: "21252e", bg1: "2e3440", bg2: "272c36", bg3: "3b4252",
                          bord: "3b4252", fg: "eceff4", fg2: "d8dee9", fg3: "7b88a1",
                          green: "a3be8c", blue: "81a1c1", purple: "b48ead", yellow: "ebcb8b", red: "bf616a",
                          tfg: "d8dee9", tdim: "69758d", isDark: true)
        case .twilight:
            return QTheme(acc: "7aa2f7", bg0: "13131a", bg1: "1a1b26", bg2: "16161e", bg3: "292e42",
                          bord: "292e42", fg: "c0caf5", fg2: "a9b1d6", fg3: "565f89",
                          green: "9ece6a", blue: "7dcfff", purple: "bb9af7", yellow: "e0af68", red: "f7768e",
                          tfg: "a9b1d6", tdim: "565f89", isDark: true)
        case .ember:
            return QTheme(acc: "fabd2f", bg0: "1b1b1b", bg1: "282828", bg2: "1d2021", bg3: "3c3836",
                          bord: "3c3836", fg: "ebdbb2", fg2: "d5c4a1", fg3: "928374",
                          green: "b8bb26", blue: "83a598", purple: "d3869b", yellow: "fabd2f", red: "fb4934",
                          tfg: "ebdbb2", tdim: "928374", isDark: true)
        case .daylight:
            // Neutral light scheme: white terminal/panes (bg1), gray chrome (bg0),
            // brand teal accent that reads on white.
            return QTheme(acc: "0d9488", bg0: "ececed", bg1: "ffffff", bg2: "f5f5f6", bg3: "e4e4e7",
                          bord: "d6d6db", fg: "18181b", fg2: "52525b", fg3: "9494a0",
                          green: "16a34a", blue: "2563eb", purple: "7c3aed", yellow: "b45309", red: "dc2626",
                          tfg: "1f2937", tdim: "9ca3af", isDark: false)
        case .paper:
            return QTheme(acc: "268bd2", bg0: "e7e0cc", bg1: "fdf6e3", bg2: "eee8d5", bg3: "ded8c3",
                          bord: "d3ccb6", fg: "073642", fg2: "586e75", fg3: "93a1a1",
                          green: "859900", blue: "268bd2", purple: "6c71c4", yellow: "b58900", red: "dc322f",
                          tfg: "586e75", tdim: "93a1a1", isDark: false)
        }
    }

    // MARK: Hex helper

    /// Parses a 6-digit hex string (with or without a leading `#`) into an
    /// sRGB `NSColor`. Falls back to opaque black on malformed input.
    static func color(_ hex: String) -> NSColor {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
