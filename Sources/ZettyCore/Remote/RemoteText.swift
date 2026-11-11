import Foundation

/// Text another Mac sent, made safe to show: a refusal reason or a machine
/// name can come from a peer that never passed admission.
public enum RemoteText {
    /// Drops control characters (C0, DEL, C1, so no escape sequence reaches
    /// a terminal: an OSC 52 could write the clipboard) and every invisible
    /// format character (bidi overrides, zero-width joiners: one name could
    /// read as another), then caps the length.
    ///
    /// It also blanks long runs of base64url characters (20 or more) and the
    /// old `zetty-pair-` prefix: a refusal has no business carrying a token
    /// for someone to copy (security review, 2026-11-05).
    public static func displayable(_ text: String, limit: Int = 300) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v < 0x20 || (0x7F ... 0x9F).contains(v) { return false }
            return scalar.properties.generalCategory != .format
        }
        var plain = String(String.UnicodeScalarView(kept))
        plain = plain.replacingOccurrences(of: "zetty-pair-", with: "…", options: .caseInsensitive)
        plain = plain.replacingOccurrences(of: "[A-Za-z0-9_+/=-]{20,}", with: "…", options: .regularExpression)
        return plain.count > limit ? String(plain.prefix(limit)) + "…" : plain
    }
}
