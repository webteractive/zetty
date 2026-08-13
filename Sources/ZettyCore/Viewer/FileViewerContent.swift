import Foundation

/// Decides whether a file's bytes can be shown in the viewer, and caps how
/// much of it is rendered.
public enum FileViewerContent {

    /// Line ceiling for a previewed file. A constant rather than a config key:
    /// a peek that needs more than this wants a real editor.
    public static let maxLines = 20_000

    /// Bytes sniffed for NULs when deciding text vs. binary.
    static let sniffWindow = 8192

    public enum Classification: Equatable, Sendable {
        /// Renderable text. `truncatedAtLine` is the cut point when the file
        /// exceeded `maxLines`, so the UI can say so.
        case text(String, truncatedAtLine: Int?)
        case binary
        case tooLarge(bytes: Int)
        /// No bytes to render. Its own case rather than `.text("")` because a
        /// zero-character body draws an empty panel that is indistinguishable
        /// from a broken viewer — the caller must say *why* there's nothing.
        case empty
    }

    public static func classify(_ data: Data, maxBytes: Int) -> Classification {
        if data.count > maxBytes { return .tooLarge(bytes: data.count) }
        if data.isEmpty { return .empty }
        if data.prefix(sniffWindow).contains(0) { return .binary }

        // Lossy on purpose: a stray invalid byte shouldn't block a peek.
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return .text(text, truncatedAtLine: nil) }
        lines = Array(lines.prefix(maxLines))
        return .text(lines.joined(separator: "\n"), truncatedAtLine: maxLines)
    }
}
