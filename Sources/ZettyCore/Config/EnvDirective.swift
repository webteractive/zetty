import Foundation

/// Validation for values Zetty renders into ghostty `env` directives.
///
/// Each directive is emitted as a single line, `env = KEY=VALUE`
/// (`SurfaceRegistry.pair(for:)`), and libghostty validates its config
/// **all-or-nothing**: one directive it rejects frees the WHOLE config —
/// including the per-surface `command` that attaches a preserved zmx session,
/// so every pane silently falls back to a plain shell. That failure cost four
/// relaunches to diagnose once already.
///
/// The existing rejection fallback cannot rescue us here, because it re-applies
/// Zetty's own directives — the offending `env` line included. So env values are
/// checked *before* they can reach the surface, not repaired afterwards.
public enum EnvDirective {

    /// Whether `key`/`value` can be rendered as one safe directive line.
    ///
    /// Rejects: an empty (or whitespace-only) key or value; any control
    /// character in either half — newlines above all, since a newline in a
    /// one-line directive is config *injection* rather than a parse error; and
    /// `=` in the key, which ghostty would split on, silently moving part of the
    /// key into the value.
    public static func isValid(key: String, value: String) -> Bool {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty,
              !value.trimmingCharacters(in: .whitespaces).isEmpty,
              !key.contains("="),
              !containsControlCharacter(key),
              !containsControlCharacter(value)
        else { return false }
        return true
    }

    /// The subset of `env` that is safe to render. Dropping a bad pair loses one
    /// variable; passing it through loses every pane's session.
    public static func sanitized(_ env: [String: String]) -> [String: String] {
        env.filter { isValid(key: $0.key, value: $0.value) }
    }

    private static func containsControlCharacter(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
