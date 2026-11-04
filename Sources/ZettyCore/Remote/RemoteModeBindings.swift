import Foundation

/// What a key binding does while another Mac's project is showing. Phase 2
/// opens panes but changes nothing on that Mac, so only navigation of this
/// Mac's own view works; everything that would edit a workspace is
/// unavailable, and must never reach the hidden local project instead.
public enum RemoteModeBindings {
    public enum Effect: Equatable, Sendable {
        case focus(FocusDirection)
        case cycleFocus
        case nextTab
        case previousTab
        case selectTab(Int)
        /// Prefix housekeeping, handled as usual.
        case passThrough
        /// Beep and do nothing.
        case unavailable
    }

    public static func effect(of command: BindingCommand) -> Effect {
        switch command {
        case .focusLeft: return .focus(.left)
        case .focusRight: return .focus(.right)
        case .focusUp: return .focus(.up)
        case .focusDown: return .focus(.down)
        case .cyclePanes: return .cycleFocus
        case .nextTab: return .nextTab
        case .previousTab: return .previousTab
        case .selectTab(let index): return .selectTab(index)
        case .cancelPrefix, .sendPrefixLiteral: return .passThrough
        // Structural edits, file tree, broadcast, tiles, zoom, copy mode and
        // the prefix paste. ⌘V still pastes through the terminal view itself.
        default: return .unavailable
        }
    }

    /// A command-palette entry for the shown remote project.
    public struct PaletteEntry: Equatable, Sendable {
        public let glyph: String
        public let label: String
        public let kbd: String
        public let effect: Effect
    }

    /// What the palette offers in place of its tab and pane verbs while
    /// another Mac's project shows: the same navigation the prefix keys do,
    /// with "Go to Tab" naming that project's tabs. The local verbs would
    /// act on the hidden local project instead.
    public static func paletteEntries(tabTitles: [String], selectedTab: Int) -> [PaletteEntry] {
        var entries = [
            PaletteEntry(glyph: "→", label: "Next Tab", kbd: "⌘}", effect: .nextTab),
            PaletteEntry(glyph: "←", label: "Previous Tab", kbd: "⌘{", effect: .previousTab),
        ]
        for (index, title) in tabTitles.enumerated() where index != selectedTab {
            entries.append(PaletteEntry(glyph: "▸", label: "Go to Tab: \(title)", kbd: "", effect: .selectTab(index + 1)))
        }
        return entries + [
            PaletteEntry(glyph: "←", label: "Focus Pane Left", kbd: "⌃B h", effect: .focus(.left)),
            PaletteEntry(glyph: "→", label: "Focus Pane Right", kbd: "⌃B l", effect: .focus(.right)),
            PaletteEntry(glyph: "↑", label: "Focus Pane Up", kbd: "⌃B k", effect: .focus(.up)),
            PaletteEntry(glyph: "↓", label: "Focus Pane Down", kbd: "⌃B j", effect: .focus(.down)),
            PaletteEntry(glyph: "↺", label: "Cycle Pane Focus", kbd: "⌃B o", effect: .cycleFocus),
        ]
    }
}
