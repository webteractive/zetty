import Foundation

/// Broadcast (synchronized input) mode. When active, a keystroke in the focused
/// pane is mirrored to a resolved set of panes. Not a `KeyMode`: keys keep
/// flowing (the engine stays `.normal`); the App layer decides to fan out.
public enum BroadcastScope: Sendable, Equatable {
    case off
    case currentTab   // every pane in the focused tab
    case workspace    // every pane in every project/tab
    case agents       // only panes running a resolved AI agent

    public var isActive: Bool { self != .off }
}

public enum Broadcast {
    /// Resolves the target surface IDs for a scope. Pure so it's testable and
    /// recomputed per send (panes opened/closed mid-broadcast are handled).
    ///
    /// - Parameters:
    ///   - currentTabSurfaces: surface IDs in the focused tab.
    ///   - allSurfaces: every surface ID in the workspace.
    ///   - hasAgent: whether a surface has a resolved agent (for `.agents`).
    public static func targets(
        scope: BroadcastScope,
        currentTabSurfaces: [UUID],
        allSurfaces: [UUID],
        hasAgent: (UUID) -> Bool
    ) -> [UUID] {
        switch scope {
        case .off: return []
        case .currentTab: return currentTabSurfaces
        case .workspace: return allSurfaces
        case .agents: return allSurfaces.filter(hasAgent)
        }
    }
}

public extension KeyChord {
    /// The bytes this chord sends to a terminal as plain input, or nil when it
    /// isn't a simple text/control/named key (best-effort — used by broadcast
    /// fan-out and `send-prefix`; exotic modified/dead keys are not encoded).
    var terminalBytes: String? {
        switch key {
        case .named(let named):
            switch named {
            case .enter: return "\r"
            case .tab: return modifiers.contains(.shift) ? "\u{1b}[Z" : "\t"
            case .escape: return "\u{1b}"
            case .space: return " "
            case .backspace: return "\u{7f}"
            case .left: return "\u{1b}[D"
            case .right: return "\u{1b}[C"
            case .up: return "\u{1b}[A"
            case .down: return "\u{1b}[B"
            }
        case .character(let character):
            // ctrl+letter → C0 control byte (a=0x01 … z=0x1A).
            if modifiers.contains(.ctrl), let ascii = character.asciiValue,
               (97...122).contains(ascii) {
                return String(UnicodeScalar(ascii - 96))
            }
            // cmd/alt combos aren't plain text — don't guess.
            if modifiers.contains(.cmd) || modifiers.contains(.alt) { return nil }
            // Plain character (shift already baked into the character).
            return String(character)
        }
    }
}
