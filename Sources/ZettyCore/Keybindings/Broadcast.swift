import Foundation

/// Broadcast (synchronized input) mode. When active, a keystroke in the focused
/// pane is mirrored to a resolved set of panes. Not a `KeyMode`: keys keep
/// flowing (the engine stays `.normal`); the App layer decides to fan out.
public enum BroadcastScope: Sendable, Equatable {
    case off
    case currentTab   // split panes in the focused tab
    case project      // every pane in every tab of the active project
    case agents       // only panes running a resolved AI agent (anywhere)
    case workspace    // every pane in every project/tab

    public var isActive: Bool { self != .off }

    /// The scope as the status bar names it, on the pill and in the menu it
    /// folds into at narrow widths. One source so the two can't drift.
    public var displayLabel: String {
        switch self {
        case .off: return "OFF"
        case .currentTab: return "TAB"
        case .project: return "PROJECT"
        case .agents: return "AGENTS"
        case .workspace: return "WORKSPACE"
        }
    }

    /// Stable string code for persistence (per-project settings). `.off` has no
    /// code — an absent/nil stored value means Off.
    public var code: String? {
        switch self {
        case .off: return nil
        case .currentTab: return "tab"
        case .project: return "project"
        case .agents: return "agents"
        case .workspace: return "workspace"
        }
    }

    /// Parses a stored code; nil/unknown → `.off`.
    public init(code: String?) {
        switch code {
        case "tab": self = .currentTab
        case "project": self = .project
        case "agents": self = .agents
        case "workspace": self = .workspace
        default: self = .off
        }
    }

    /// Next scope for a single cycling toggle key:
    /// Off → Tab → Project → Agents → Workspace → Off.
    public var next: BroadcastScope {
        switch self {
        case .off:        return .currentTab
        case .currentTab: return .project
        case .project:    return .agents
        case .agents:     return .workspace
        case .workspace:  return .off
        }
    }
}

public enum Broadcast {
    /// Resolves the target surface IDs for a scope. Pure so it's testable and
    /// recomputed per send (panes opened/closed mid-broadcast are handled).
    ///
    /// - Parameters:
    ///   - currentTabSurfaces: surface IDs in the focused tab.
    ///   - currentProjectSurfaces: surface IDs across the active project's tabs.
    ///   - allSurfaces: every surface ID in the workspace.
    ///   - hasAgent: whether a surface has a resolved agent (for `.agents`).
    public static func targets(
        scope: BroadcastScope,
        currentTabSurfaces: [UUID],
        currentProjectSurfaces: [UUID],
        allSurfaces: [UUID],
        hasAgent: (UUID) -> Bool
    ) -> [UUID] {
        switch scope {
        case .off: return []
        case .currentTab: return currentTabSurfaces
        case .project: return currentProjectSurfaces
        case .workspace: return allSurfaces
        case .agents: return allSurfaces.filter(hasAgent)
        }
    }
}

public extension KeyChord {
    /// The C0 byte a Control chord sends in a terminal's legacy encoding,
    /// as the focused pane gets it: letters either case (Ctrl+Shift+A is
    /// 0x01), `@ [ \\ ] ^ _`, and xterm's digit and punctuation aliases.
    /// nil for a Control chord with none (Ctrl+1): broadcast leaves it to
    /// the focused pane rather than typing the bare character everywhere,
    /// which put a literal `[` in every pane for vim's Ctrl+[ (release
    /// review, 2026-11-20).
    static func legacyControlByte(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 97...122: return ascii - 96                    // a … z
        case 64...95: return ascii - 64                     // @ A … Z [ \ ] ^ _
        case UInt8(ascii: "2"), UInt8(ascii: "`"): return 0x00
        case UInt8(ascii: "6"): return 0x1E
        case UInt8(ascii: "/"), UInt8(ascii: "-"): return 0x1F
        case UInt8(ascii: "?"): return 0x7F
        default: return nil
        }
    }

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
            case .space: return modifiers.contains(.ctrl) ? "\u{0}" : " "
            case .backspace: return "\u{7f}"
            case .left: return "\u{1b}[D"
            case .right: return "\u{1b}[C"
            case .up: return "\u{1b}[A"
            case .down: return "\u{1b}[B"
            }
        case .character(let character):
            if modifiers.contains(.ctrl) {
                guard !modifiers.contains(.cmd), !modifiers.contains(.alt),
                      let byte = character.asciiValue.flatMap(Self.legacyControlByte) else { return nil }
                return String(UnicodeScalar(byte))
            }
            // cmd/alt combos aren't plain text — don't guess.
            if modifiers.contains(.cmd) || modifiers.contains(.alt) { return nil }
            // Plain character (shift already baked into the character).
            return String(character)
        }
    }
}
