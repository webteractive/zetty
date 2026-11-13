import Foundation

/// POSIX shell quoting for text Zetty types into a pane.
public enum ShellQuote {
    /// Wraps `s` in single quotes; an embedded `'` becomes `'\''` (close,
    /// escaped quote, reopen). Inside single quotes nothing else is special,
    /// so this is enough to make an arbitrary path or id inert.
    public static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Whether `s` can be TYPED into a pane. Quoting makes text inert to the
    /// shell's parser, but typed text reaches the line editor first, where a
    /// control character is a key: a folder named "x<^U>curl …|sh<CR>"
    /// clears the line and runs the rest (bug hunt, 2026-11-13). No C0
    /// control, DEL or C1 control.
    public static func isTypeable(_ s: String) -> Bool {
        !s.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// `cd '<directory>' && `, or nothing when the directory can't be typed:
    /// the pane already starts there, so the line still works without it.
    public static func changeDirectoryPrefix(_ directory: String) -> String {
        isTypeable(directory) ? "cd \(singleQuoted(directory)) && " : ""
    }
}
