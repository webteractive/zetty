import Foundation

/// Encodes a `zetty send` payload as a ghostty `text:` binding action.
///
/// `ghostty_surface_text` has paste semantics: when the foreground program
/// enables bracketed paste (zsh's line editor, most TUIs), the payload is
/// framed as literal paste content, so `\r` never submits and control keys
/// never act. The `text:` binding action instead performs a raw pty write —
/// input-identical to typing — which is what synthetic CLI input needs.
///
/// The action's value is parsed as a Zig string literal, so the payload is
/// escaped: backslashes doubled, control bytes and DEL as `\xNN` (which also
/// keeps the action string free of raw control characters), everything else
/// passed through verbatim (UTF-8 survives untouched).
public enum GhosttyTextAction {
    public static func encode(_ payload: String) -> String {
        var value = ""
        value.reserveCapacity(payload.count)
        for scalar in payload.unicodeScalars {
            switch scalar.value {
            case 0x5C:                       // backslash
                value += #"\\"#
            case ..<0x20, 0x7F:              // control bytes + DEL
                value += String(format: #"\x%02x"#, scalar.value)
            default:
                value.unicodeScalars.append(scalar)
            }
        }
        return "text:" + value
    }
}
