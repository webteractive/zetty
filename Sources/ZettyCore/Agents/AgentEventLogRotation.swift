import Foundation

/// Bounds the hook-event log (`~/.zetty/agent-events.jsonl`).
///
/// Harness hooks append to the log forever; nothing ever removed a line, so a
/// busy workspace grows it without limit. Only the tail is ever read (the
/// watcher tails new lines, and the startup replay reduces a bounded suffix),
/// so everything before that suffix is dead weight.
///
/// Trimming happens once at startup, before the watcher seeds its read offset —
/// never while it is tailing, which would make the offset point mid-file.
public enum AgentEventLogRotation {

    /// Rotate once the log passes this size.
    public static let defaultMaxBytes = 1024 * 1024

    /// How much of the tail to keep when rotating. Must stay >= the replay
    /// window (`AgentEventReplay` reads 256 KB) or rotation would discard state
    /// the replay still needs to restore status dots.
    public static let defaultKeepBytes = 256 * 1024

    /// The trimmed contents for an oversized log, or nil when it should be left
    /// alone.
    ///
    /// The kept suffix starts at the first newline inside the window, so a
    /// rotation can never leave a partial JSON line at the head of the file. A
    /// window containing no newline at all (one absurdly long line) yields nil —
    /// there is no safe cut point, and truncating mid-line would corrupt it.
    public static func trimmed(
        _ data: Data,
        maxBytes: Int = defaultMaxBytes,
        keepBytes: Int = defaultKeepBytes
    ) -> Data? {
        guard maxBytes > 0, keepBytes > 0, data.count > maxBytes else { return nil }
        let window = data.suffix(keepBytes)
        // `firstIndex` returns an index into `data` (SubSequence shares indices).
        guard let newline = window.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let start = window.index(after: newline)
        guard start < data.endIndex else { return nil }
        return Data(data[start...])
    }
}
