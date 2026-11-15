import Foundation

/// Pure precedence helper for tab display titles.
///
/// Precedence:
/// 1. Non-empty, trimmed `manualTitle` (the user's own name)
/// 2. Non-empty `agentName` — the AI agent running in the pane, combined with
///    the title the CLI emits when there is one: `"claude code: <emitted>"`,
///    or the agent name alone otherwise
/// 3. `focusedSurfaceTitle` **when it names a running command** — the terminal's
///    reported foreground process, ignoring bare shell names (an idle shell
///    shouldn't hijack the tab title)
/// 4. Non-empty last path component of `workingDir` (the pwd — the idle default)
/// 5. Positional fallback: `"Tab \(index + 1)"`
public enum TabTitle {

    /// Shell process names that mean "idle at a prompt", not a running command.
    private static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "login", "-zsh", "-bash", "-fish",
    ]

    public static func display(
        manualTitle: String?,
        agentName: String? = nil,
        focusedSurfaceTitle: String?,
        workingDir: String?,
        index: Int
    ) -> String {
        // 1. Manual title.
        if let title = manualTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return title
        }

        // 2. Detected agent names the tab, carrying the CLI's own title along.
        if let agent = agentName?.trimmingCharacters(in: .whitespaces), !agent.isEmpty {
            if let title = focusedSurfaceTitle?.trimmingCharacters(in: .whitespaces),
               !title.isEmpty, !isShellName(title) {
                return "\(agent): \(title)"
            }
            return agent
        }

        // 3. The running command (terminal title), unless it's just a shell.
        if let title = focusedSurfaceTitle?.trimmingCharacters(in: .whitespaces),
           !title.isEmpty, !isShellName(title) {
            return title
        }

        // 4. The pwd basename (skip empty/whitespace and the root "/").
        if let path = workingDir {
            let component = URL(fileURLWithPath: path).lastPathComponent
                .trimmingCharacters(in: .whitespaces)
            if !component.isEmpty, component != "/" {
                return component
            }
        }

        // 5. Positional fallback.
        return "Tab \(index + 1)"
    }

    /// The status glyphs agents put in front of their titles: braille spinner
    /// frames (U+2800–U+28FF), half circles, and Claude Code's stars and dot.
    private static let statusGlyphs: Set<Character> = ["◐", "◓", "◑", "◒", "✢", "✳", "✶", "✻", "✽", "·"]

    /// `title` without a leading agent status glyph and the space after it.
    /// Zetty shows the pane's status itself (the dot), and a glyph persisted
    /// in `lastTitle` would be a spinner frozen mid-turn after a relaunch.
    /// A title that is nothing but glyphs is returned unchanged.
    public static func strippingStatusGlyph(_ title: String) -> String {
        var rest = Substring(title)
        while let first = rest.first, isStatusGlyph(first) { rest = rest.dropFirst() }
        guard rest.count < title.count else { return title }
        let trimmed = rest.drop(while: { $0.isWhitespace })
        return trimmed.isEmpty ? title : String(trimmed)
    }

    private static func isStatusGlyph(_ character: Character) -> Bool {
        if statusGlyphs.contains(character) { return true }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return (0x2800...0x28FF).contains(scalar.value)
    }

    /// True if `title` is just a shell process name (idle prompt), not a command.
    static func isShellName(_ title: String) -> Bool {
        shellNames.contains(title.lowercased())
    }
}
