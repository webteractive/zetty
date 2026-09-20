import Foundation

/// Parses `ps`'s cumulative CPU `time` column.
///
/// The format is `[[dd-]hh:]mm:ss.ss` and its shape changes with magnitude, so
/// the field count cannot be assumed. Splitting on ":" alone loses the day
/// part entirely and reports a week-old process as minutes old.
public enum CPUTime {

    /// Seconds of CPU consumed, or nil when the field is not a time.
    public static func seconds(from field: String) -> Double? {
        var text = field.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var days = 0.0
        if let dash = text.firstIndex(of: "-") {
            guard let parsed = Double(text[text.startIndex ..< dash]), parsed >= 0 else { return nil }
            days = parsed
            text = String(text[text.index(after: dash)...])
        }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count) else { return nil }

        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return days * 86400 + total
    }
}
