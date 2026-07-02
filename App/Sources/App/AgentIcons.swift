import AppKit
import ZettyCore

/// Logos for the popular agent CLIs shown in tab pills.
///
/// A bundled image asset named `agent-<kind>` (e.g. `agent-claude`) always
/// wins, so real brand artwork can be dropped in later. Until then each kind
/// gets a small glyph medallion rendered as a template image, tinted by the
/// tab to match its text color. Kinds without either show no logo — the tab
/// falls back to weaving the agent name into its text.
@MainActor
enum AgentIcons {

    private static let glyphs: [AgentKind: String] = [
        .claude: "✳",
        .codex: "⬡",
        .opencode: "▣",
        .aider: "◆",
        .gemini: "✦",
        .hermes: "☿",
    ]

    private static var cache: [AgentKind: NSImage] = [:]
    private static var toolCache: [String: NSImage?] = [:]

    /// Logo for a non-agent tool (vim, …), matched by its foreground command
    /// name against the bundled `agent-<name>.svg` files. Nil when we don't
    /// ship one — the tab just shows the emitted title.
    static func icon(forTool command: String) -> NSImage? {
        let name = command.lowercased()
        if let cached = toolCache[name] { return cached }
        let image = bundledLogo(named: "agent-\(name)")
        toolCache[name] = image
        return image
    }

    static func icon(for kind: AgentKind) -> NSImage? {
        if let cached = cache[kind] { return cached }
        if let bundled = bundledLogo(named: "agent-\(kind.rawValue)") {
            cache[kind] = bundled
            return bundled
        }
        guard let glyph = glyphs[kind] else { return nil }

        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.black,   // template: tint comes from the view
            ]
            let string = NSAttributedString(string: glyph, attributes: attributes)
            let glyphSize = string.size()
            string.draw(at: NSPoint(
                x: rect.midX - glyphSize.width / 2,
                y: rect.midY - glyphSize.height / 2
            ))
            return true
        }
        image.isTemplate = true
        cache[kind] = image
        return image
    }

    /// Bundled brand SVG (App/Resources/AgentLogos, from the open-source
    /// simple-icons and lobe-icons sets — monochrome, so they tint cleanly).
    private static func bundledLogo(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg")
                ?? Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "AgentLogos"),
              let image = NSImage(contentsOf: url), image.size.width > 1
        else { return nil }
        image.isTemplate = true
        return image
    }
}
