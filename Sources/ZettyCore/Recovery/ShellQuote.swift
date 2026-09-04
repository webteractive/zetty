import Foundation

/// POSIX shell quoting for text Zetty types into a pane.
public enum ShellQuote {
    /// Wraps `s` in single quotes; an embedded `'` becomes `'\''` (close,
    /// escaped quote, reopen). Inside single quotes nothing else is special,
    /// so this is enough to make an arbitrary path or id inert.
    public static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
