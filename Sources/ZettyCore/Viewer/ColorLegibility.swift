import Foundation

/// Whether a syntax-highlight colour is readable against the viewer's
/// background.
///
/// The file viewer's highlighter is an arbitrary user-configured subprocess
/// (`viewer-highlight-command`), so the colours it emits are **absolute** — they
/// come from that tool's own theme, not from `ZTheme`. A highlighter set up for
/// a dark theme emits near-white text; rendered on a light scheme's white `bg1`
/// that is invisible, and the peek looks like an empty panel rather than a
/// mis-coloured one. (This was a real report: bat defaults to a dark theme and
/// emits xterm 231 — pure white — for ordinary body text.)
///
/// Zetty picks a matching theme for the default highlighter, but it cannot do
/// that for every possible command, so this is the backstop: any run whose
/// colour is too close to the background is dropped in favour of the scheme's
/// own foreground token. Legibility wins over fidelity.
///
/// Pure by design (plain RGB components, no AppKit) so it is unit-testable.
public enum ColorLegibility {

    /// Contrast below which a run is treated as unreadable and recoloured.
    ///
    /// WCAG's text thresholds (4.5 / 3.0) are far too aggressive here: syntax
    /// themes legitimately dim comments, and forcing those up to 4.5 would
    /// flatten the palette into a single colour. This only catches genuinely
    /// invisible text — 1.0 is "identical to the background", and the default
    /// 1.6 leaves dim-but-visible comments alone.
    public static let defaultMinimumRatio: Double = 1.6

    /// WCAG 2.1 relative luminance of an sRGB colour (components 0...1).
    public static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ component: Double) -> Double {
            let c = min(max(component, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.1 contrast ratio between two sRGB colours — 1.0 (identical) to
    /// 21.0 (black on white).
    public static func contrastRatio(
        foreground: (red: Double, green: Double, blue: Double),
        background: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let a = relativeLuminance(red: foreground.red, green: foreground.green, blue: foreground.blue)
        let b = relativeLuminance(red: background.red, green: background.green, blue: background.blue)
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Whether `foreground` is readable on `background`.
    public static func isLegible(
        foreground: (red: Double, green: Double, blue: Double),
        background: (red: Double, green: Double, blue: Double),
        minimumRatio: Double = defaultMinimumRatio
    ) -> Bool {
        contrastRatio(foreground: foreground, background: background) >= minimumRatio
    }
}
