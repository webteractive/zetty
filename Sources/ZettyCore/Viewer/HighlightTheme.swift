import Foundation

/// Picks the environment a `viewer-highlight-command` subprocess runs with, so
/// its syntax colours match the *active Zetty scheme's* light/dark axis.
///
/// The highlighter is a separate program with its own theme, and it has no way
/// to know what Zetty is showing: `bat` run without a TTY can't detect a
/// background colour, so it falls back to a dark theme and emits near-white
/// text. On a light scheme that renders white-on-white — the peek looks empty
/// rather than merely mis-coloured.
///
/// The fix is an environment variable rather than an appended `--theme` flag:
/// the command is user-configurable, so Zetty must not rewrite its arguments.
/// `BAT_THEME_DARK`/`BAT_THEME_LIGHT` are inert for a non-bat highlighter, and
/// an explicit `--theme` in the user's own command still wins over them.
public enum HighlightTheme {

    /// bat's built-in themes closest to Zetty's own surface ramp.
    public static let darkTheme = "Monokai Extended"
    public static let lightTheme = "Monokai Extended Light"

    /// Environment entries that pin the highlighter to `isDark`'s axis, merged
    /// over the caller's base environment.
    ///
    /// `BAT_THEME` is set as well as the axis-specific pair because bat only
    /// consults `BAT_THEME_DARK`/`BAT_THEME_LIGHT` when it can detect the
    /// terminal background — which, with no TTY, it cannot.
    public static func environment(isDark: Bool) -> [String: String] {
        let theme = isDark ? darkTheme : lightTheme
        return [
            "BAT_THEME": theme,
            "BAT_THEME_DARK": darkTheme,
            "BAT_THEME_LIGHT": lightTheme,
        ]
    }
}
