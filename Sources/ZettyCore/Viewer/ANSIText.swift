import Foundation

/// A foreground colour from an SGR sequence. Indexes 0–15 stay palette-bound
/// so the App layer can map them onto `ZTheme` tokens instead of baking in
/// xterm's defaults.
public enum ANSIColor: Equatable, Sendable {
    case indexed(Int)
    case rgb(r: Int, g: Int, b: Int)
}

public struct ANSIStyle: Equatable, Sendable {
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    /// nil = the viewer's default foreground.
    public var foreground: ANSIColor?

    public init(bold: Bool = false, italic: Bool = false,
                underline: Bool = false, foreground: ANSIColor? = nil) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.foreground = foreground
    }
}

/// A stretch of text sharing one style.
public struct ANSIRun: Equatable, Sendable {
    public let text: String
    public let style: ANSIStyle

    public init(text: String, style: ANSIStyle) {
        self.text = text
        self.style = style
    }
}

/// Parses SGR (`ESC[…m`) sequences into styled runs. This is what buys the
/// viewer full-language highlighting without shipping a highlighter: `bat`
/// emits the colours, this turns them into attributes.
///
/// Non-style CSI sequences (`K`, `H`, `J`, …) are consumed and dropped;
/// malformed or unterminated escapes survive as literal text rather than
/// throwing away the rest of the file.
public enum ANSIText {

    public static func parse(_ raw: String) -> [ANSIRun] {
        let chars = Array(raw)
        var runs: [ANSIRun] = []
        var style = ANSIStyle()
        var buffer = ""
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(ANSIRun(text: buffer, style: style))
            buffer = ""
        }

        while i < chars.count {
            // Anything but a CSI introducer is content.
            guard chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" else {
                buffer.append(chars[i])
                i += 1
                continue
            }
            // Scan the parameter bytes up to the sequence's final byte.
            var j = i + 2
            var params = ""
            while j < chars.count, !isFinalByte(chars[j]) {
                params.append(chars[j])
                j += 1
            }
            guard j < chars.count else {
                // Unterminated: the remainder is literal text.
                buffer.append(contentsOf: chars[i...])
                break
            }
            if chars[j] == "m" {
                flush()
                style = applying(params, to: style)
            }
            i = j + 1
        }
        flush()
        return runs
    }

    private static func isFinalByte(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue else { return false }
        return ascii >= 0x40 && ascii <= 0x7E
    }

    static func applying(_ params: String, to base: ANSIStyle) -> ANSIStyle {
        var style = base
        // An empty parameter list means 0 (reset), as does a non-numeric one.
        let codes = params
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        var k = 0
        while k < codes.count {
            switch codes[k] {
            case 0: style = ANSIStyle()
            case 1: style.bold = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.foreground = .indexed(codes[k] - 30)
            case 39: style.foreground = nil
            case 90...97: style.foreground = .indexed(codes[k] - 90 + 8)
            case 38:
                if k + 2 < codes.count, codes[k + 1] == 5 {
                    style.foreground = color256(codes[k + 2])
                    k += 2
                } else if k + 4 < codes.count, codes[k + 1] == 2 {
                    style.foreground = .rgb(r: codes[k + 2], g: codes[k + 3], b: codes[k + 4])
                    k += 4
                }
            default:
                break   // backgrounds (40–49, 100–107) and everything else.
            }
            k += 1
        }
        return style
    }

    /// xterm-256 → colour: 0–15 palette-bound, 16–231 the 6×6×6 cube,
    /// 232–255 the 24-step grey ramp.
    static func color256(_ n: Int) -> ANSIColor? {
        switch n {
        case 0...15:
            return .indexed(n)
        case 16...231:
            let levels = [0, 95, 135, 175, 215, 255]
            let v = n - 16
            return .rgb(r: levels[v / 36], g: levels[(v / 6) % 6], b: levels[v % 6])
        case 232...255:
            let grey = 8 + (n - 232) * 10
            return .rgb(r: grey, g: grey, b: grey)
        default:
            return nil
        }
    }
}
