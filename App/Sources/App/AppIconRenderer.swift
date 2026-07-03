import AppKit

/// Renders the Zetty app icon from the ACTIVE color scheme, so the Dock icon
/// follows theme changes while the app runs (the bundled .icns stays the
/// static Twilight rendition for Finder and the login switcher).
///
/// Composition: squircle plate on the scheme's surface ramp, then a terminal
/// prompt mark — a dim `>`, the glowing accent Z, and a chunky cursor bar
/// exactly as tall as the Z — set in IBM Plex Mono Bold (bundled). Layout is
/// CoreText-ink based: glyph image bounds (not advances) are centered on the
/// plate, and the `>` is centered on the Z's vertical midline. Pass
/// `cursorVisible: false` for the blink's "off" frame; the layout doesn't
/// shift. Call on the main thread (it reads ZTheme and uses AppKit drawing).
enum AppIconRenderer {

    /// Registers every bundled font for this process — IBM Plex Mono (the icon
    /// mark) and JetBrains Mono (the default chrome/terminal font, so the
    /// default renders identically on machines without it installed). Idempotent;
    /// call once at launch before the first render.
    static func registerBundledFont() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func plexBold(size: CGFloat) -> NSFont {
        NSFont(name: "IBMPlexMono-Bold", size: size) ?? ZTheme.monoFont(size: size, weight: .bold)
    }

    /// Draws the icon at Dock resolution using `ZTheme.current` tokens.
    static func image(size canvas: CGFloat = 512, cursorVisible: Bool = true) -> NSImage {
        let theme = ZTheme.current
        let scale = canvas / 1024
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        // ── Squircle plate (surface ramp) ───────────────────────────
        let margin = 100 * scale
        let plate = NSRect(x: margin, y: margin,
                           width: canvas - 2 * margin, height: canvas - 2 * margin)
        let platePath = NSBezierPath(roundedRect: plate, xRadius: 184 * scale, yRadius: 184 * scale)
        NSGraphicsContext.current?.saveGraphicsState()
        platePath.setClip()
        NSGradient(colors: [theme.bg3Color, theme.bg0Color])?.draw(in: plate, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        theme.borderColor.setStroke()
        let border = NSBezierPath(roundedRect: plate.insetBy(dx: 3 * scale, dy: 3 * scale),
                                  xRadius: 181 * scale, yRadius: 181 * scale)
        border.lineWidth = 6 * scale
        border.stroke()

        // ── The mark: "> Z |" ink-centered on the plate ─────────────
        let zLine = CTLineCreateWithAttributedString(NSAttributedString(string: "Z", attributes: [
            .font: plexBold(size: 420 * scale), .foregroundColor: theme.accentColor,
        ]))
        let promptLine = CTLineCreateWithAttributedString(NSAttributedString(string: ">", attributes: [
            .font: plexBold(size: 320 * scale), .foregroundColor: theme.fg3Color,
        ]))
        let zInk = CTLineGetImageBounds(zLine, ctx)          // relative to baseline origin
        let promptInk = CTLineGetImageBounds(promptLine, ctx)

        let barWidth = 110 * scale
        let gap = 48 * scale
        let totalInk = promptInk.width + gap + zInk.width + gap + barWidth
        let inkStartX = (canvas - totalInk) / 2
        let midlineY = canvas / 2

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 52 * scale,
                      color: theme.accentColor.withAlphaComponent(0.85).cgColor)

        // The ">" and the Z share a vertical midline; the bar spans the Z's ink.
        ctx.textPosition = CGPoint(x: inkStartX - promptInk.minX,
                                   y: midlineY - promptInk.midY)
        CTLineDraw(promptLine, ctx)
        let zBaselineY = midlineY - zInk.midY
        ctx.textPosition = CGPoint(x: inkStartX + promptInk.width + gap - zInk.minX,
                                   y: zBaselineY)
        CTLineDraw(zLine, ctx)

        if cursorVisible {
            let bar = CGRect(x: inkStartX + promptInk.width + gap + zInk.width + gap,
                             y: zBaselineY + zInk.minY,
                             width: barWidth, height: zInk.height)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 24 * scale,
                               cornerHeight: 24 * scale, transform: nil))
            ctx.setFillColor(theme.accentColor.cgColor)
            ctx.fillPath()
        }
        ctx.restoreGState()

        image.unlockFocus()
        return image
    }
}
