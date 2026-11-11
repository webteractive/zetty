import Foundation

/// The name Zetty's own Tailscale device goes by. It always starts with
/// `zetty-`: peers can't see which app made a device (Tailscale shares only
/// a device's name, OS and services with other devices), so the name is how
/// one Zetty tells another Zetty from the Mac's own Tailscale device, which
/// carries everything else on that Mac (`PeerAdmission`).
public enum ZettyDeviceName {
    public static let prefix = "zetty-"
    /// A DNS label's limit.
    static let maxLength = 63

    /// `zetty-` and this Mac's name, lowercased and DNS-safe.
    public static func defaultName(hostName: String) -> String {
        let label = sanitized(hostName)
        return prefix + (label.isEmpty ? "mac" : label)
    }

    /// What a rename in Settings becomes: the prefix plus the typed name,
    /// sanitized. Input with nothing usable keeps `current`.
    public static func normalized(_ input: String, keeping current: String) -> String {
        var label = sanitized(input)
        if label.hasPrefix(prefix) { label.removeFirst(prefix.count) }
        return label.isEmpty || label == "zetty" ? current : prefix + label
    }

    /// True for a Zetty device name: the prefix, any case, and something after it.
    public static func isZetty(_ hostName: String) -> Bool {
        let lower = hostName.lowercased()
        return lower.hasPrefix(prefix) && lower.count > prefix.count
    }

    /// The part after `zetty-`, which is what Settings lets people edit.
    public static func suffix(of name: String) -> String {
        name.lowercased().hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    /// Lowercase letters and digits, runs of anything else as one hyphen, no
    /// hyphen at either end, short enough to fit behind the prefix.
    private static func sanitized(_ text: String) -> String {
        var out = ""
        var pendingHyphen = false
        for scalar in text.lowercased().unicodeScalars {
            if scalar == "’" || scalar == "'" { continue }
            if ("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)) {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        let room = maxLength - prefix.count
        if out.count > room {
            out = String(out.prefix(room))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out
    }
}
