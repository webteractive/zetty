import Foundation

// MARK: - ChordModifiers

/// Modifier set for a key chord. AppKit-independent so the engine and config
/// parsing stay pure; the app layer maps `NSEvent.modifierFlags` onto this.
public struct ChordModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let ctrl = ChordModifiers(rawValue: 1 << 0)
    public static let shift = ChordModifiers(rawValue: 1 << 1)
    public static let alt = ChordModifiers(rawValue: 1 << 2)
    public static let cmd = ChordModifiers(rawValue: 1 << 3)
}

// MARK: - NamedKey

/// Non-printable keys addressable from config chords.
public enum NamedKey: String, Hashable, Sendable, CaseIterable {
    case up, down, left, right
    case escape, enter, tab, space, backspace
}

// MARK: - ChordKey

/// The base key of a chord: a printable character (shift baked in, so `%`
/// rather than shift+5) or a named non-printable key.
public enum ChordKey: Hashable, Sendable {
    case character(Character)
    case named(NamedKey)
}

// MARK: - KeyChord

/// One key press with modifiers, in config syntax like `ctrl+b`, `%`,
/// `shift+up`. Matching follows the shift rule: for `.character` keys the
/// shift modifier is ignored (it's already baked into the character), for
/// `.named` keys shift is significant.
public struct KeyChord: Hashable, Sendable {
    public var key: ChordKey
    public var modifiers: ChordModifiers

    public init(key: ChordKey, modifiers: ChordModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    // MARK: Parsing

    private static let modifierNames: [String: ChordModifiers] = [
        "ctrl": .ctrl, "control": .ctrl,
        "shift": .shift,
        "alt": .alt, "opt": .alt, "option": .alt,
        "cmd": .cmd, "command": .cmd,
    ]

    /// Parses a config chord (`ctrl+b`, `%`, `shift+cmd+x`, `escape`,
    /// `ctrl+space`). Modifier words and named keys are case-insensitive;
    /// single characters keep their case (an uppercase letter means the
    /// shifted key, so `G` ≠ `g`). Whitespace-trimmed. Returns nil for
    /// malformed input (empty, dangling `+`, repeated modifiers, unknown
    /// multi-character key names).
    public static func parse(_ text: String) -> KeyChord? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }   // dangling or doubled `+`

        var modifiers: ChordModifiers = []
        for part in parts.dropLast() {
            guard let modifier = modifierNames[part.lowercased()] else { return nil }
            guard !modifiers.contains(modifier) else { return nil }   // repeated modifier
            modifiers.insert(modifier)
        }

        guard let last = parts.last else { return nil }
        if modifierNames[last.lowercased()] != nil { return nil }     // bare/trailing modifier

        let key: ChordKey
        if last.count == 1, let character = last.first {
            key = .character(character)
        } else if let named = NamedKey(rawValue: last.lowercased()) {
            key = .named(named)
        } else {
            return nil
        }
        return KeyChord(key: key, modifiers: modifiers)
    }

    // MARK: Matching

    /// Chord equality with the shift rule (see type docs).
    public func matches(_ other: KeyChord) -> Bool {
        normalized == other.normalized
    }

    /// The canonical position of a chord in a binding table. For `.character`
    /// keys shift folds into the character itself: `shift+g` becomes `G`, and
    /// symbols produced with shift (`%`) simply drop the modifier — so table
    /// lookups agree with `matches(_:)` however the chord was written or
    /// pressed.
    public var normalized: KeyChord {
        switch key {
        case .character(let character):
            let shifted = modifiers.contains(.shift) && character.isLowercase
                ? Character(character.uppercased())
                : character
            return KeyChord(key: .character(shifted), modifiers: modifiers.subtracting(.shift))
        case .named:
            return self
        }
    }

    // MARK: Config rendering

    /// Renders back to config syntax (`ctrl+b`, `shift+up`, `%`).
    public var configDescription: String {
        var parts: [String] = []
        if modifiers.contains(.ctrl) { parts.append("ctrl") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.alt) { parts.append("alt") }
        if modifiers.contains(.cmd) { parts.append("cmd") }
        switch key {
        case .character(let character):
            parts.append(String(character))
        case .named(let named):
            parts.append(named.rawValue)
        }
        return parts.joined(separator: "+")
    }
}
