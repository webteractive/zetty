import AppKit
import GhosttyTerminal

// MARK: - Theme
//
// The single source of truth for Zetty's visual design, translated from the
// Claude Design handoff `Zetty.dc.html`
// (project def4312f-4b6c-41d2-ae44-98d0d130c35b).
//
// RULES (see DESIGN.md):
//   • Never hardcode a color in a view. Read it from `ZTheme.current`.
//   • All terminal / label / tab / status text uses `ZTheme.monoFont`; only
//     prose and system chrome use the system font.
//   • Active / selected states use `accent` with a soft glow, never a heavy fill.
//   • Adding a scheme means filling EVERY token below — no partial schemes.

/// The selectable color schemes carried over verbatim from the handoff's
/// `schemes` map. `midnight` is the default.
enum ZColorScheme: String, CaseIterable {
    // Dark axis.
    case midnight, nocturne, frost, twilight, ember, velvet, eclipse, rosewood, neon, ukiyo
    // Light axis.
    case daylight, paper, glacier, dawn, latte, porcelain, harvest, citrus, daybreak, sakura

    var displayName: String {
        switch self {
        case .midnight:  return "Midnight"
        case .nocturne:  return "Nocturne"
        case .frost:     return "Frost"
        case .twilight:  return "Twilight"
        case .ember:     return "Ember"
        case .velvet:    return "Velvet"
        case .eclipse:   return "Eclipse"
        case .rosewood:  return "Rosewood"
        case .neon:      return "Neon"
        case .ukiyo:     return "Ukiyo"
        case .daylight:  return "Daylight"
        case .paper:     return "Paper"
        case .glacier:   return "Glacier"
        case .dawn:      return "Dawn"
        case .latte:     return "Latte"
        case .porcelain: return "Porcelain"
        case .harvest:   return "Harvest"
        case .citrus:    return "Citrus"
        case .daybreak:  return "Daybreak"
        case .sakura:    return "Sakura"
        }
    }

    /// Case-insensitive lookup by display name or raw value (used to resolve
    /// scheme names from the config file). Returns `nil` for unknown names.
    static func named(_ name: String) -> ZColorScheme? {
        let key = name.lowercased()
        return allCases.first { $0.rawValue == key || $0.displayName.lowercased() == key }
    }

    /// Whether this scheme is a dark scheme (drives which axis it belongs to).
    var isDark: Bool { ZTheme.palette(for: self).isDark }

    /// Schemes for the dark / light axis, in declaration order.
    static var darkSchemes: [ZColorScheme] { allCases.filter(\.isDark) }
    static var lightSchemes: [ZColorScheme] { allCases.filter { !$0.isDark } }
}

/// A fully-specified palette. Values are hex strings WITHOUT a leading `#`
/// (ghostty's config parser and our `NSColor` helper both accept that form),
/// so the same token feeds both the AppKit chrome and the libghostty terminal.
struct ZTheme {

    // Design tokens (mirror the CSS custom properties in Zetty.dc.html).
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
    static var scheme: ZColorScheme = .midnight {
        didSet { current = ZTheme.palette(for: scheme) }
    }

    /// The palette for the active scheme. Views read tokens from here.
    private(set) static var current: ZTheme = ZTheme.palette(for: .midnight)

    // MARK: NSColor accessors

    var accentColor: NSColor { ZTheme.color(acc) }
    var bg0Color: NSColor    { ZTheme.color(bg0) }
    var bg1Color: NSColor    { ZTheme.color(bg1) }
    var bg2Color: NSColor    { ZTheme.color(bg2) }
    var bg3Color: NSColor    { ZTheme.color(bg3) }
    var borderColor: NSColor { ZTheme.color(bord) }
    var fgColor: NSColor     { ZTheme.color(fg) }
    var fg2Color: NSColor    { ZTheme.color(fg2) }
    var fg3Color: NSColor    { ZTheme.color(fg3) }
    var greenColor: NSColor  { ZTheme.color(green) }
    var yellowColor: NSColor { ZTheme.color(yellow) }
    var purpleColor: NSColor { ZTheme.color(purple) }
    var redColor: NSColor    { ZTheme.color(red) }

    /// The AppKit appearance that matches this scheme, so native chrome
    /// (menus, scrollers, the titlebar) tracks the palette.
    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    // MARK: Fonts

    /// Registers every bundled font (JetBrains Mono, the default chrome/terminal
    /// face) for this process so defaults render identically on machines without
    /// them installed. Idempotent; call once at launch before the first render.
    static func registerBundledFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Ghostty's default `font-size` — the baseline `fontScale` is derived from.
    static let defaultFontSize: CGFloat = 13

    /// Chrome text scale bounds: the terminal honors any `font-size`, but chrome
    /// rows/tabs have fixed heights, so their text scale is clamped to keep fitting.
    static let chromeScaleRange: ClosedRange<CGFloat> = 0.85...1.35

    /// The user's `font-family` config directive; `nil` → the default chain
    /// (JetBrains Mono, else the system monospaced face). Set by the app layer
    /// whenever config is loaded or changed, so chrome tracks the terminal font.
    static var fontFamily: String?

    /// Chrome text scale derived from the `font-size` directive (÷ 13, clamped).
    /// Applied inside `monoFont` so every chrome call site follows along.
    static var fontScale: CGFloat = 1

    /// Derives `fontFamily`/`fontScale` from the effective config directives.
    static func setFont(family: String?, size: CGFloat?) {
        fontFamily = family
        let scale = (size ?? defaultFontSize) / defaultFontSize
        fontScale = min(max(scale, chromeScaleRange.lowerBound), chromeScaleRange.upperBound)
    }

    /// The user's configured font when set and installed (weight-matched via
    /// NSFontManager), else JetBrains Mono (the handoff's font), else the system
    /// monospaced face. Used for terminal-adjacent UI: tabs, sidebar tree,
    /// status bar, kbd chips. `size` is the design size at scale 1 — the user's
    /// `font-size` scales it uniformly.
    static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let scaled = size * fontScale
        if let family = fontFamily, let custom = customFont(family: family, size: scaled, weight: weight) {
            return custom
        }
        if let jb = NSFont(name: monoPostScriptName(for: weight), size: scaled) {
            return jb
        }
        return .monospacedSystemFont(ofSize: scaled, weight: weight)
    }

    /// System (proportional) font for standard chrome — tabs, sidebar, palette,
    /// dialogs, chips. Deliberately decoupled from the user's terminal
    /// `font-family`/`font-size`: only the terminal and the status bar follow
    /// `monoFont`. Fixed point size (no `fontScale`).
    static func chromeFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Resolves a weight-appropriate member of `family`, or its regular face,
    /// or `nil` when the family isn't installed (callers fall back to default).
    private static func customFont(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let manager = NSFontManager.shared
        let fontWeight = Int(round(5 + weight.rawValue * 10))  // NSFontManager's 0–15 scale, 5 = regular
        if let font = manager.font(withFamily: family, traits: [], weight: fontWeight, size: size) {
            return font
        }
        return NSFont(name: family, size: size)
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

    // MARK: Palettes (from Zetty.dc.html `schemes`)

    static func palette(for scheme: ZColorScheme) -> ZTheme {
        switch scheme {
        case .midnight:
            return ZTheme(acc: "5eead4", bg0: "09090c", bg1: "0b0b0f", bg2: "131319", bg3: "1a1a22",
                          bord: "1f1f27", fg: "e6e6ea", fg2: "a7a7b2", fg3: "6a6a75",
                          green: "7ee787", blue: "7c9cff", purple: "d2a8ff", yellow: "e3b341", red: "ff7b72",
                          tfg: "c9d1d9", tdim: "6e7681", isDark: true)
        case .nocturne:
            return ZTheme(acc: "bd93f9", bg0: "191a21", bg1: "282a36", bg2: "21222c", bg3: "343746",
                          bord: "343746", fg: "f8f8f2", fg2: "c3c5d6", fg3: "6272a4",
                          green: "50fa7b", blue: "8be9fd", purple: "ff79c6", yellow: "f1fa8c", red: "ff5555",
                          tfg: "f8f8f2", tdim: "6272a4", isDark: true)
        case .frost:
            return ZTheme(acc: "88c0d0", bg0: "21252e", bg1: "2e3440", bg2: "272c36", bg3: "3b4252",
                          bord: "3b4252", fg: "eceff4", fg2: "d8dee9", fg3: "7b88a1",
                          green: "a3be8c", blue: "81a1c1", purple: "b48ead", yellow: "ebcb8b", red: "bf616a",
                          tfg: "d8dee9", tdim: "69758d", isDark: true)
        case .twilight:
            return ZTheme(acc: "7aa2f7", bg0: "13131a", bg1: "1a1b26", bg2: "16161e", bg3: "292e42",
                          bord: "292e42", fg: "c0caf5", fg2: "a9b1d6", fg3: "565f89",
                          green: "9ece6a", blue: "7dcfff", purple: "bb9af7", yellow: "e0af68", red: "f7768e",
                          tfg: "a9b1d6", tdim: "565f89", isDark: true)
        case .ember:
            return ZTheme(acc: "fabd2f", bg0: "1b1b1b", bg1: "282828", bg2: "1d2021", bg3: "3c3836",
                          bord: "3c3836", fg: "ebdbb2", fg2: "d5c4a1", fg3: "928374",
                          green: "b8bb26", blue: "83a598", purple: "d3869b", yellow: "fabd2f", red: "fb4934",
                          tfg: "ebdbb2", tdim: "928374", isDark: true)
        case .velvet:
            // Catppuccin Mocha: plush near-black with a mauve glow.
            return ZTheme(acc: "cba6f7", bg0: "11111b", bg1: "1e1e2e", bg2: "181825", bg3: "313244",
                          bord: "313244", fg: "cdd6f4", fg2: "a6adc8", fg3: "6c7086",
                          green: "a6e3a1", blue: "89b4fa", purple: "f5c2e7", yellow: "f9e2af", red: "f38ba8",
                          tfg: "cdd6f4", tdim: "6c7086", isDark: true)
        case .eclipse:
            // One Dark: the Atom classic, steel gray with a cool blue accent.
            return ZTheme(acc: "61afef", bg0: "21252b", bg1: "282c34", bg2: "2c313a", bg3: "3e4451",
                          bord: "3e4451", fg: "d7dae0", fg2: "abb2bf", fg3: "5c6370",
                          green: "98c379", blue: "61afef", purple: "c678dd", yellow: "e5c07b", red: "e06c75",
                          tfg: "abb2bf", tdim: "5c6370", isDark: true)
        case .rosewood:
            // Rosé Pine: muted violet dusk with a soft rose accent.
            return ZTheme(acc: "ebbcba", bg0: "13111b", bg1: "191724", bg2: "1f1d2e", bg3: "26233a",
                          bord: "26233a", fg: "e0def4", fg2: "908caa", fg3: "6e6a86",
                          green: "9ccfd8", blue: "6ea7c0", purple: "c4a7e7", yellow: "f6c177", red: "eb6f92",
                          tfg: "e0def4", tdim: "6e6a86", isDark: true)
        case .neon:
            // Monokai Pro: warm charcoal with high-voltage sign colors.
            return ZTheme(acc: "ffd866", bg0: "221f22", bg1: "2d2a2e", bg2: "322f34", bg3: "403e41",
                          bord: "403e41", fg: "fcfcfa", fg2: "c1c0c0", fg3: "727072",
                          green: "a9dc76", blue: "78dce8", purple: "ab9df2", yellow: "ffd866", red: "ff6188",
                          tfg: "fcfcfa", tdim: "727072", isDark: true)
        case .ukiyo:
            // Kanagawa: sumi ink with woodblock-print pigments.
            return ZTheme(acc: "7e9cd8", bg0: "16161d", bg1: "1f1f28", bg2: "2a2a37", bg3: "363646",
                          bord: "363646", fg: "dcd7ba", fg2: "c8c093", fg3: "727169",
                          green: "98bb6c", blue: "7fb4ca", purple: "957fb8", yellow: "e6c384", red: "e46876",
                          tfg: "dcd7ba", tdim: "727169", isDark: true)
        case .daylight:
            // Neutral light scheme: white terminal/panes (bg1), gray chrome (bg0),
            // brand teal accent that reads on white.
            return ZTheme(acc: "0d9488", bg0: "ececed", bg1: "ffffff", bg2: "f5f5f6", bg3: "e4e4e7",
                          bord: "d6d6db", fg: "18181b", fg2: "52525b", fg3: "9494a0",
                          green: "16a34a", blue: "2563eb", purple: "7c3aed", yellow: "b45309", red: "dc2626",
                          tfg: "1f2937", tdim: "9ca3af", isDark: false)
        case .paper:
            return ZTheme(acc: "268bd2", bg0: "e7e0cc", bg1: "fdf6e3", bg2: "eee8d5", bg3: "ded8c3",
                          bord: "d3ccb6", fg: "073642", fg2: "586e75", fg3: "93a1a1",
                          green: "859900", blue: "268bd2", purple: "6c71c4", yellow: "b58900", red: "dc322f",
                          tfg: "586e75", tdim: "93a1a1", isDark: false)
        case .glacier:
            // Nord light: polar blue-grays; semantic colors deepened to read on snow.
            return ZTheme(acc: "5e81ac", bg0: "e0e6ef", bg1: "eceff4", bg2: "e5e9f0", bg3: "d8dee9",
                          bord: "cdd6e3", fg: "2e3440", fg2: "4c566a", fg3: "8892a5",
                          green: "5d7e4d", blue: "5e81ac", purple: "9a6a90", yellow: "c08a24", red: "bf616a",
                          tfg: "3b4252", tdim: "94a3b8", isDark: false)
        case .dawn:
            // Rosé Pine Dawn: warm parchment with dusty rose.
            return ZTheme(acc: "d7827e", bg0: "f2e9e1", bg1: "faf4ed", bg2: "fffaf3", bg3: "e6dcd1",
                          bord: "dcd0c4", fg: "575279", fg2: "797593", fg3: "9893a5",
                          green: "56949f", blue: "286983", purple: "907aa9", yellow: "ea9d34", red: "b4637a",
                          tfg: "575279", tdim: "9893a5", isDark: false)
        case .latte:
            // Catppuccin Latte: cool porcelain blues with a mauve accent.
            return ZTheme(acc: "8839ef", bg0: "dce0e8", bg1: "eff1f5", bg2: "e6e9ef", bg3: "ccd0da",
                          bord: "bcc0cc", fg: "4c4f69", fg2: "5c5f77", fg3: "8c8fa1",
                          green: "40a02b", blue: "1e66f5", purple: "8839ef", yellow: "df8e1d", red: "d20f39",
                          tfg: "4c4f69", tdim: "9ca0b0", isDark: false)
        case .porcelain:
            // GitHub light: crisp white with the familiar diff palette.
            return ZTheme(acc: "0969da", bg0: "eaeef2", bg1: "ffffff", bg2: "f6f8fa", bg3: "dfe5eb",
                          bord: "d0d7de", fg: "24292f", fg2: "57606a", fg3: "8c959f",
                          green: "1a7f37", blue: "0969da", purple: "8250df", yellow: "9a6700", red: "cf222e",
                          tfg: "24292f", tdim: "6e7781", isDark: false)
        case .harvest:
            // Gruvbox light: cream and wheat with retro print inks.
            return ZTheme(acc: "d65d0e", bg0: "ebdbb2", bg1: "fbf1c7", bg2: "f2e5bc", bg3: "ddcca7",
                          bord: "d5c4a1", fg: "3c3836", fg2: "504945", fg3: "928374",
                          green: "79740e", blue: "076678", purple: "8f3f71", yellow: "b57614", red: "9d0006",
                          tfg: "3c3836", tdim: "928374", isDark: false)
        case .citrus:
            // Ayu light: airy off-white with a zesty orange accent.
            return ZTheme(acc: "e6650f", bg0: "efeff0", bg1: "fcfcfc", bg2: "f3f4f5", bg3: "e7e8e9",
                          bord: "d9dadb", fg: "434a50", fg2: "5c6166", fg3: "8a9199",
                          green: "6f9400", blue: "399ee6", purple: "a37acc", yellow: "c28510", red: "d63f3f",
                          tfg: "5c6166", tdim: "a0a6ab", isDark: false)
        case .daybreak:
            // Tokyo Night Day: cool periwinkle grays with ink-blue text.
            return ZTheme(acc: "2e7de9", bg0: "d0d5e3", bg1: "e1e2e7", bg2: "e9e9ee", bg3: "c4c8da",
                          bord: "b4b8cd", fg: "343b58", fg2: "5a607d", fg3: "8990b3",
                          green: "587539", blue: "2e7de9", purple: "9854f1", yellow: "8c6c3e", red: "f52a65",
                          tfg: "343b58", tdim: "8990b3", isDark: false)
        case .sakura:
            // Cherry-blossom light: blush surfaces with a deep pink accent.
            return ZTheme(acc: "c94f7c", bg0: "f3dde5", bg1: "fff7fa", bg2: "fbeef3", bg3: "f0dbe4",
                          bord: "e3c7d3", fg: "432c3c", fg2: "7a5468", fg3: "a8869a",
                          green: "3c8f63", blue: "3b76c9", purple: "9061c2", yellow: "b3801f", red: "cf3f56",
                          tfg: "4b2f3f", tdim: "a8869a", isDark: false)
        }
    }

    // MARK: Project identity palette

    /// Curated per-project colors (design doc: a fixed palette, not free hex).
    /// Deliberately offset from the semantic status hues — green (running),
    /// yellow (attention), red (error), purple (git) — and from the accent,
    /// which stays reserved for focus/brand. Each id carries an appearance
    /// pair: a bright variant for dark schemes and a deeper one for light
    /// schemes, so the color stays legible on either `bg1`. Stored in
    /// project settings by `id` so the hex can be tuned later without
    /// re-assigning anyone's projects.
    static let projectPalette: [(id: String, dark: String, light: String)] = [
        ("sky",    "6db3f2", "2d6fb5"),
        ("teal",   "5fc4c4", "1f8a8a"),
        ("moss",   "93c47d", "4e7d3a"),
        ("sand",   "d4b483", "8f6f3f"),
        ("orange", "e8a06a", "b5651f"),
        ("pink",   "e895bd", "b54f82"),
        ("mauve",  "c39fdd", "7d4fa8"),
        ("steel",  "9fb0c1", "5a6b7d"),
    ]

    /// The NSColor for a stored palette id under the CURRENT appearance
    /// (bright variant on dark schemes, deep variant on light); nil for
    /// nil/unknown ids (a removed palette entry degrades to "no color",
    /// never an error). Reactive: callers re-resolve on every render, and
    /// chrome re-renders on scheme/appearance changes.
    static func projectColor(id: String?) -> NSColor? {
        guard let id, let entry = projectPalette.first(where: { $0.id == id }) else { return nil }
        return color(current.isDark ? entry.dark : entry.light)
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
