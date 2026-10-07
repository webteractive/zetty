import Foundation

/// Reads an agent's input box off a pane's screen (`zmx history --vt`), so
/// `hibernate-after` never puts away a project where somebody left a draft.
/// Ported from Tinker, which reads the same box before typing into a chat.
///
/// Claude's idle box is a `❯` line between two rules of `─`; the top rule may carry the session name:
///
///     ──────────────────────── Cool-chat-cool-fd1d8fcf ─
///     ❯
///     ──────────────────────────────────────────────────
///
/// A draft puts text after the `❯`, and a question replaces the box with a menu whose selected row
/// reads `❯ 1. Yes`, so only a `❯` followed by nothing but whitespace is empty. Scrollback keeps
/// earlier boxes; the last `❯` line on the screen is the input Claude has now, and it decides.
public enum PromptBox {
    static let prompt: Character = "❯"
    static let rule: Character = "─"

    /// `true` only when the last prompt line is empty and framed by rules above and below.
    /// Anything unrecognised is `false`: typing into a screen we can't read is never safe.
    public static func isEmpty(screen: String) -> Bool {
        let lines = screen.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let index = lines.lastIndex(where: { $0.drop(while: \.isWhitespace).first == prompt }),
              index > lines.startIndex, index < lines.endIndex - 1 else { return false }
        let input = lines[index].drop(while: \.isWhitespace).dropFirst()
        return input.allSatisfy(\.isWhitespace) && isRule(lines[index - 1]) && isRule(lines[index + 1])
    }

    /// `isEmpty(screen:)` for the screen as `zmx history --vt` gives it, styling and all, with
    /// faint text taken out first. An empty box in a new or cleared conversation shows a faint
    /// suggestion (`❯ Try "create a util logging.py that..."`, measured on 2.1.289), which plain
    /// text can't tell from a draft; typed text is never faint.
    ///
    /// Only that suggestion is let through: the faint text must read `Try "…"`. Anything else drawn
    /// faint in the box (a pasted-text or image chip, if Claude ever draws one faint) is a draft.
    public static func isEmpty(vtScreen: String) -> Bool {
        guard isEmpty(screen: withoutFaintText(vtScreen)) else { return false }
        let plain = withoutFaintText(vtScreen, keepFaint: true)
        let lines = plain.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let input = lines.last(where: { $0.drop(while: \.isWhitespace).first == prompt }) else { return false }
        let typed = input.drop(while: \.isWhitespace).dropFirst().trimmingCharacters(in: .whitespaces)
        return typed.isEmpty || typed.hasPrefix("Try \"")
    }

    /// The screen with every escape sequence removed and every run drawn faint (SGR 2) dropped.
    /// SGR is read parameter by parameter, so a colour like `38;2;136;136;136` — a `2` that is part
    /// of a colour, not faint — is skipped whole.
    static func withoutFaintText(_ vt: String, keepFaint: Bool = false) -> String {
        var output = ""
        var faint = false
        let scalars = Array(vt.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\u{1B}", index + 1 < scalars.count else {
                if keepFaint || !faint || scalar == "\n" || scalar == "\r" { output.unicodeScalars.append(scalar) }
                index += 1
                continue
            }
            let kind = scalars[index + 1]
            index += 2
            switch kind {
            case "[":
                // CSI: parameter and intermediate bytes, then one final byte in @…~.
                var body = ""
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
                    body.unicodeScalars.append(scalars[index])
                    index += 1
                }
                let final = index < scalars.count ? scalars[index] : " "
                index += 1
                if final == "m", body.first.map({ $0.isNumber || $0 == ";" }) ?? true {
                    faint = applySGR(body, faint: faint)
                }
            case "]":
                // OSC: up to BEL or ESC \.
                while index < scalars.count, scalars[index] != "\u{07}", scalars[index] != "\u{1B}" { index += 1 }
                if index < scalars.count, scalars[index] == "\u{1B}" { index += 1 }
                index += 1
            case "(", ")", "*", "+":
                index += 1
            default:
                break
            }
        }
        return output
    }

    private static func applySGR(_ body: String, faint: Bool) -> Bool {
        let params = body.isEmpty ? [0] : body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var faint = faint
        var index = 0
        while index < params.count {
            switch params[index] {
            case 0, 22: faint = false
            case 2: faint = true
            case 38, 48, 58:
                // An extended colour: 5;n or 2;r;g;b.
                if index + 1 < params.count { index += params[index + 1] == 5 ? 2 : params[index + 1] == 2 ? 4 : 1 }
            default: break
            }
            index += 1
        }
        return faint
    }

    /// A line that starts and ends with `─`, like the box's borders (the top one may hold a name).
    static func isRule(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.first == rule && trimmed.last == rule
    }
}

extension PromptBox {
    static let codexPrompt: Character = "›"

    /// `isEmpty(vtScreen:)` for the harness in the pane. A harness with no
    /// reader is never empty: a screen we cannot read may hold a draft.
    public static func isEmpty(vtScreen: String, agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return isEmpty(vtScreen: vtScreen)
        case .codex:  return isCodexComposerEmpty(vtScreen: vtScreen)
        default:      return false
        }
    }

    /// Codex's composer is the last line starting `›`: bold `› ` and then a
    /// FAINT placeholder when it is empty, typed text when it is not, and a
    /// menu row (`› 1. Yes, proceed`) while it asks. It has no rules around it.
    ///
    /// It looks the same while Codex works, so an `esc to interrupt` line
    /// anywhere on the screen makes it not empty: Codex's one hook (turn
    /// ended) cannot tell working from idle, and this is the only thing that
    /// can. Read off codex 0.160.1.
    static func isCodexComposerEmpty(vtScreen: String) -> Bool {
        // The hint is itself drawn faint, so it is looked for with faint text kept.
        guard !withoutFaintText(vtScreen, keepFaint: true).contains("esc to interrupt") else { return false }
        let lines = withoutFaintText(vtScreen)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let composer = lines.last(where: { $0.drop(while: \.isWhitespace).first == codexPrompt })
        else { return false }
        return composer.drop(while: \.isWhitespace).dropFirst().allSatisfy(\.isWhitespace)
    }

    /// The end of a pane's history, which is all a reader looks at: a
    /// preserved pane's scrollback can run to megabytes. Cut forward to a
    /// line start, so the first line is never half of one.
    public static func tail(of history: Data, limit: Int = 64 * 1024) -> String {
        guard history.count > limit else { return String(decoding: history, as: UTF8.self) }
        let slice = history.suffix(limit)
        let start = slice.firstIndex(of: 0x0A).map { slice.index(after: $0) } ?? slice.startIndex
        return String(decoding: slice[start...], as: UTF8.self)
    }
}
