import Foundation

/// Makes a captured VT stream safe to replay into a fresh shell.
///
/// `zmx history --vt` reproduces the bytes the pane emitted, and a full-screen
/// agent that was killed by the power-off never got to undo its terminal
/// modes. Its snapshot therefore carries one each of `?1049h` (alternate
/// screen), `?1000h`/`?1002h`/`?1003h`/`?1006h` (mouse reporting) and `?2004h`
/// (bracketed paste), with no matching resets.
///
/// Replaying that verbatim leaves the pane hostile: the shell runs inside the
/// alternate screen (so the replay is invisible in scrollback) and mouse
/// reporting stays ON with no TUI to consume it, so every pointer movement
/// types an escape sequence at the prompt. Observed for real — a recovered
/// pane filled with `zsh: command not found: 39`, and the mouse bytes
/// interleaved with the resume command being typed into it, so that pane's
/// agent never came back.
///
/// The fix is to keep the drawing and drop the mode changes: DEC private mode
/// sequences are stripped, and a short reset trailer is appended.
public enum SnapshotSanitizer {

    /// Reset appended after the stripped stream: scroll margins, character
    /// attributes, cursor visibility, and mouse reporting off. Belt and braces
    /// — stripping already removes the enables; this also covers a stream that
    /// set them in a form the scanner doesn't recognise.
    static let resetTrailer = "\u{1B}[r\u{1B}[0m\u{1B}[?25h"
        + "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?2004l"

    /// Strips every DEC private mode set/reset (`ESC [ ? … h` / `… l`) and any
    /// scroll-region change (`ESC [ … r`), then appends `resetTrailer`.
    ///
    /// Text, cursor positioning and SGR colour are untouched, so the replayed
    /// screen looks the same — it just no longer reconfigures the terminal it
    /// lands in. Stripping resets as well as sets is deliberate: a static
    /// replay needs neither, and a lone reset for a mode we removed the set
    /// for is noise.
    public static func sanitized(snapshot data: Data) -> Data {
        var out = Data(capacity: data.count + resetTrailer.utf8.count)
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5B else {  // ESC [
                out.append(bytes[i])
                i += 1
                continue
            }
            // Scan the parameter bytes of a CSI sequence.
            var j = i + 2
            let isPrivate = j < bytes.count && bytes[j] == 0x3F   // '?'
            if isPrivate { j += 1 }
            while j < bytes.count, (0x30...0x39).contains(bytes[j]) || bytes[j] == 0x3B { j += 1 }
            guard j < bytes.count else {
                // Truncated escape at the end of the capture — emit as-is.
                out.append(contentsOf: bytes[i...])
                break
            }
            let final = bytes[j]
            let dropped = (isPrivate && (final == 0x68 || final == 0x6C))   // ?…h / ?…l
                || (!isPrivate && final == 0x72)                            // …r (scroll region)
            if dropped {
                i = j + 1
            } else {
                out.append(contentsOf: bytes[i...j])
                i = j + 1
            }
        }
        out.append(contentsOf: Array(resetTrailer.utf8))
        return out
    }
}
