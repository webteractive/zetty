import Foundation

/// Turns a handover `ssh://[user@]host[:port]` URL (delivered by macOS from
/// another app) into a safe `ssh` command string, or `nil` when the URL is not
/// a valid/safe ssh target.
///
/// Security: the URL is untrusted external input. Every component is validated
/// against a strict charset and the command is assembled from validated tokens
/// only — the raw URL string is never interpolated into a shell, so a crafted
/// host/user cannot inject shell commands.
public enum SSHURLHandler {
    /// Host/user tokens: letters, digits, dot, hyphen, underscore. No spaces,
    /// no shell metacharacters, no path separators, and no leading hyphen,
    /// which ssh would read as an option (`ssh://-Ex@host`).
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    private static func isSafe(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("-") && token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func command(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "ssh" else { return nil }

        guard let host = components.host, isSafe(host) else { return nil }

        var target = host
        if let user = components.user {
            guard isSafe(user) else { return nil }
            target = "\(user)@\(host)"
        }

        var parts = ["ssh"]
        if let port = components.port {
            guard (1...65535).contains(port) else { return nil }
            parts.append("-p")
            parts.append(String(port))
        }
        parts.append(target)
        return parts.joined(separator: " ")
    }
}
