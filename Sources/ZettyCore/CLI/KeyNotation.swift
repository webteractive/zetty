import Foundation

/// tmux-style key names → the bytes to write to the pty.
///
/// Used by `quertty send --key <name>`; unknown names return nil so the CLI
/// can reject them up front instead of injecting garbage.
public enum KeyNotation {

    private static let named: [String: String] = [
        "enter": "\r",
        "return": "\r",
        "tab": "\t",
        "btab": "\u{1b}[Z",       // Shift+Tab
        "escape": "\u{1b}",
        "esc": "\u{1b}",
        "space": " ",
        "bspace": "\u{7f}",
        "backspace": "\u{7f}",
        "up": "\u{1b}[A",
        "down": "\u{1b}[B",
        "right": "\u{1b}[C",
        "left": "\u{1b}[D",
        "home": "\u{1b}[H",
        "end": "\u{1b}[F",
        "pageup": "\u{1b}[5~",
        "pagedown": "\u{1b}[6~",
        "delete": "\u{1b}[3~",
    ]

    public static func encode(_ name: String) -> String? {
        let key = name.lowercased()
        guard !key.isEmpty else { return nil }
        if let sequence = named[key] { return sequence }

        // Control chords: C-a … C-z → 0x01 … 0x1a.
        if key.hasPrefix("c-"), key.count == 3,
           let letter = key.last?.asciiValue, (97...122).contains(letter) {
            return String(UnicodeScalar(letter - 96))
        }
        return nil
    }
}
