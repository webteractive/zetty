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
    /// It looks the same while Codex works, and while a command Codex started
    /// is still running after its turn, so either hint anywhere on the screen
    /// makes it not empty. Codex's one hook (turn ended) cannot tell working
    /// from idle, and it runs its commands under a shared daemon, not under
    /// the pane, so the process table cannot show one. The screen is the only
    /// thing that can. Read off codex 0.160.1 and 0.161.0.
    static func isCodexComposerEmpty(vtScreen: String) -> Bool {
        !isCodexWorking(vtScreen) && !hasCodexTerminalRunning(vtScreen)
            && isCodexComposerBlank(vtScreen)
    }

    /// What to type into a Codex pane so nothing of its is left running when
    /// the pane's session is ended.
    public enum CodexStopStep: Equatable, Sendable {
        /// Mid-turn: Escape interrupts it. Look again afterwards.
        case interrupt
        /// At rest with a terminal still running: `/stop` closes them all.
        case stop
        case nothing
    }

    /// Codex's commands belong to its daemon and outlive the pane: a `sleep`
    /// it had started was still running after its project was hibernated.
    /// Interrupting stops the turn, not the command; `/stop` ("Stopping all
    /// background terminals") stops the command.
    ///
    /// `.stop` only with a blank composer. Typed after a draft, `/stop` would
    /// be submitted with it as a prompt, and the daemon would carry on with
    /// that turn after the pane was gone.
    public static func codexStopStep(vtScreen: String) -> CodexStopStep {
        if isCodexWorking(vtScreen) { return .interrupt }
        return hasCodexTerminalRunning(vtScreen) && isCodexComposerBlank(vtScreen) ? .stop : .nothing
    }

    /// The hints are themselves drawn faint, so they are looked for with
    /// faint text kept.
    private static func isCodexWorking(_ vtScreen: String) -> Bool {
        withoutFaintText(vtScreen, keepFaint: true).contains("esc to interrupt")
    }

    /// The whole phrase, since the words alone can be somebody's message.
    private static func hasCodexTerminalRunning(_ vtScreen: String) -> Bool {
        let everything = withoutFaintText(vtScreen, keepFaint: true)
        return everything.contains("background terminal running")
            || everything.contains("background terminals running")
    }

    private static func isCodexComposerBlank(_ vtScreen: String) -> Bool {
        let lines = withoutFaintText(vtScreen)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let composer = lines.last(where: { $0.drop(while: \.isWhitespace).first == codexPrompt })
        else { return false }
        return composer.drop(while: \.isWhitespace).dropFirst().allSatisfy(\.isWhitespace)
    }

    /// Whether a pane's agent can be handed a line to act on.
    public enum Readiness: Equatable, Sendable {
        /// An empty prompt box: what is typed now is what gets submitted.
        case ready
        /// A turn is running. Only Codex shows this; Claude's box looks the
        /// same while it works, and its hooks are what say so.
        case working
        /// A draft, a question's menu, or a screen that cannot be read:
        /// typing here would join the draft or answer the question.
        case blocked
    }

    /// Read before `/compact` is typed into a pane, and after each key sent
    /// to clear the way for it. A running terminal does not block Codex
    /// here as it does for `hibernate-after`: the turn is over.
    public static func readiness(vtScreen: String, agent: AgentKind) -> Readiness {
        switch agent {
        case .claude:
            return isEmpty(vtScreen: vtScreen) ? .ready : .blocked
        case .codex:
            if isCodexWorking(vtScreen) { return .working }
            return isCodexComposerBlank(vtScreen) ? .ready : .blocked
        default:
            return .blocked
        }
    }

    /// Whether the box holds nothing, whatever else the agent is doing. A
    /// working Codex has a composer too, and what is in it was typed by
    /// somebody; `readiness` cannot say, since working outranks it there.
    public static func boxIsEmpty(vtScreen: String, agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return isEmpty(vtScreen: vtScreen)
        case .codex:  return isCodexComposerBlank(vtScreen)
        default:      return false
        }
    }

    /// Whether the harness is compacting right now, which is the one time an
    /// empty box does not mean it has stopped: `Compacting conversation…`
    /// (Claude) and `Compacting context` (Codex), both drawn above the box.
    public static func isCompacting(vtScreen: String) -> Bool {
        let lines = withoutFaintText(vtScreen, keepFaint: true)
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        // Only the screen as it stands: a finished compaction's line scrolls
        // up and stays in the history above.
        return lines.suffix(compactingWindow).contains { $0.contains("Compacting") }
    }

    /// Whether Claude has just declined to compact because there is nothing
    /// to: `Not enough messages to compact.` Its conversation is as compact
    /// as it gets, which is a handoff, not a failure. The transcript is
    /// checked for this before asking (`HandoffCompaction.needsCompaction`);
    /// this is for whatever that check does not foresee.
    public static func saysNothingToCompact(vtScreen: String) -> Bool {
        withoutFaintText(vtScreen, keepFaint: true)
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .suffix(compactingWindow).contains { $0.contains("Not enough messages to compact") }
    }

    /// How many lines up from the bottom a harness draws its working line.
    private static let compactingWindow = 12

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
