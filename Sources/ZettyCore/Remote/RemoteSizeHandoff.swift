import Foundation

/// How a pane shown on two Macs gets the size of the screen in use.
///
/// zmx gives a session the size of the client that typed last, and sends the
/// same output to every client. A program draws for that one size, so the
/// other Mac's window, at another size, lays the output on the wrong rows and
/// columns. Taking the size back is two keys from the screen in use; a clean
/// view is a restart of that screen's attach, which clears it and replays
/// zmx's own copy, drawn at the new size. See `remote-machines.md`.
public enum RemoteSizeHandoff {
    /// Space, then Backspace. zmx 0.8.1 forwards only plain keys from a client
    /// that didn't type last (letters, space, Backspace, Tab, Enter) and drops
    /// escapes, control keys and focus reports, so this is the quietest input
    /// that switches the size. It cancels itself out in a prompt or a text
    /// field, and leaves Claude Code's permission menu where it was.
    public static let claim = " \u{7F}"

    /// How long the program gets to redraw at the new size before the screen
    /// is repainted from zmx's copy: at least `settle`, then until its output
    /// has been `quiet` that long, but never past `settleLimit`. Claude Code
    /// on a long conversation can still be redrawing at 0.4s, and a repaint
    /// then replays a half-drawn screen that stays until a key (2026-11-16).
    public static let settle: TimeInterval = 0.4
    public static let quiet: TimeInterval = 0.15
    public static let settleLimit: TimeInterval = 2.5

    /// Whether the pointer moving over a pane claims its size: only in the
    /// Zetty in use (frontmost, its window key). The terminal view tracks the
    /// pointer even when Zetty is in the background, so with Screen Sharing in
    /// front one pointer crossed both Macs' windows and flipped the pane
    /// between them, each time with a full repaint (2026-11-16).
    public static func pointerClaims(appActive: Bool, windowKey: Bool) -> Bool {
        appActive && windowKey
    }

    /// Clears the screen and its scrollback: what a repaint prints just
    /// before its replay (`SessionPersistence.clearScreenEscaped` is the same
    /// for a `printf` format).
    public static let clearScreen = "\u{1B}[H\u{1B}[2J\u{1B}[3J"

    /// What a viewing Mac's Zetty types into a remote pane's relay when the
    /// pane gains focus: an APC string, which no key produces. The relay
    /// strips it and never forwards it.
    public static let focusMarker = "\u{1B}_zetty-focus\u{1B}\\"

    /// Removes every focus marker from a chunk of the relay's input. `focused`
    /// says whether there was one.
    public static func splitFocus(_ chunk: Data) -> (input: Data, focused: Bool) {
        let marker = Data(focusMarker.utf8)
        guard chunk.range(of: marker) != nil else { return (chunk, false) }
        var rest = chunk[...]
        var input = Data()
        while let found = rest.range(of: marker) {
            input.append(rest[rest.startIndex ..< found.lowerBound])
            rest = rest[found.upperBound...]
        }
        input.append(rest)
        return (input, true)
    }
}

/// A relay's side of the handoff: whether its screen drives the session's
/// size, and the frames that take it back. Pure, so the relay's loop only
/// sends what this returns.
public struct RelaySizeDriver: Sendable {
    /// This screen typed last since attaching, or since the server said the
    /// size moved.
    public private(set) var drives = false
    /// When this screen claimed the size, while its repaint is pending.
    private var claimedAt: Date?
    private var lastOutput: Date?

    public init() {}

    /// A first attach takes the size at once: the pane was just opened here.
    /// A reconnect waits for focus or a key, since the user may be at the
    /// other Mac.
    public mutating func attached(first: Bool, now: Date) -> [TerminalFrame] {
        drives = false
        claimedAt = nil
        return first ? takeSize(now: now) : []
    }

    /// Input from the pane, focus markers included. Focus, or a key typed
    /// while another screen drives, takes the size before the key goes out.
    public mutating func input(_ chunk: Data, now: Date) -> [TerminalFrame] {
        let (input, focused) = RemoteSizeHandoff.splitFocus(chunk)
        var frames: [TerminalFrame] = []
        if !drives, focused || !input.isEmpty { frames += takeSize(now: now) }
        if !input.isEmpty { frames.append(.data(input)) }
        return frames
    }

    /// The server says another screen typed.
    public mutating func sizeMoved() {
        drives = false
    }

    /// Output from the session reached this screen.
    public mutating func output(now: Date) {
        lastOutput = now
    }

    /// The repaint, once the program has had time to redraw at this size:
    /// past `settle`, with output since the claim that has then been quiet
    /// for `quiet`, or at `settleLimit` regardless.
    ///
    /// Silence since the claim is not a redraw done: the serving Mac's
    /// attach may not have started, with the claim still unread in its pty.
    /// A repaint restarts that attach and the claim goes with it, so a
    /// repaint that never heard back sends the claim again after itself
    /// (Glen, laptop opening a mini pane, 2026-11-17).
    public mutating func due(now: Date) -> [TerminalFrame] {
        guard let claimedAt, now >= claimedAt.addingTimeInterval(RemoteSizeHandoff.settle) else { return [] }
        let answer = lastOutput.flatMap { $0 >= claimedAt ? $0 : nil }
        let quiet = answer.map { now >= $0.addingTimeInterval(RemoteSizeHandoff.quiet) } ?? false
        guard quiet || now >= claimedAt.addingTimeInterval(RemoteSizeHandoff.settleLimit) else { return [] }
        self.claimedAt = nil
        return answer == nil ? [.repaint, .data(Data(RemoteSizeHandoff.claim.utf8))] : [.repaint]
    }

    private mutating func takeSize(now: Date) -> [TerminalFrame] {
        drives = true
        claimedAt = now
        return [.data(Data(RemoteSizeHandoff.claim.utf8))]
    }
}
