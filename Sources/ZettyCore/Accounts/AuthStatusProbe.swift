import Foundation

/// How an agent's status command reports itself.
public enum AuthStatusFormat: String, Sendable, Equatable {
    /// A JSON object carrying the identity (Claude Code).
    case claudeJSON
    /// Prose that says only whether it is signed in (Codex).
    case plainText
}

/// What an agent reports about the identity behind a config directory.
public struct AccountAuthStatus: Equatable, Sendable {
    public let loggedIn: Bool
    public let email: String?
    public let orgName: String?
    public let subscriptionType: String?

    public init(loggedIn: Bool, email: String? = nil,
                orgName: String? = nil, subscriptionType: String? = nil) {
        self.loggedIn = loggedIn
        self.email = email
        self.orgName = orgName
        self.subscriptionType = subscriptionType
    }
}

/// Arguments and parsing for the sign-in status check — the pure half, split
/// from process IO the same way `GitStatus` and `CloneSupport` are.
///
/// Deliberately never run on a timer. The binary is a heavyweight CLI, it has to
/// run once PER ACCOUNT, and a GUI app's PATH can't even find it without help —
/// putting that on a refresh cadence is the `git`-pill mistake with a
/// multiplier. Identity is captured once at sign-in and cached on the account.
public enum AuthStatusProbe {

    /// Tolerant by design: nil for anything unparseable, so a CLI that changes
    /// its output shape degrades to "unknown" rather than to a wrong identity.
    public static func parse(_ output: String, format: AuthStatusFormat) -> AccountAuthStatus? {
        switch format {
        case .claudeJSON: return parseJSON(output)
        case .plainText:  return parsePlainText(output)
        }
    }

    /// Prose like "Logged in using ChatGPT" / "Not logged in" — signed-in state
    /// only, no identity. "Not logged in" is checked FIRST because it contains
    /// the affirmative phrase as a substring.
    static func parsePlainText(_ output: String) -> AccountAuthStatus? {
        let text = output.lowercased()
        if text.contains("not logged in") || text.contains("not signed in") {
            return AccountAuthStatus(loggedIn: false)
        }
        if text.contains("logged in") || text.contains("signed in") {
            return AccountAuthStatus(loggedIn: true)
        }
        return nil
    }

    static func parseJSON(_ output: String) -> AccountAuthStatus? {
        // The command may print banners around the JSON, so take the outermost
        // braces rather than assuming the whole output is the object.
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"), start < end
        else { return nil }
        let json = String(output[start...end])

        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return AccountAuthStatus(
            loggedIn: object["loggedIn"] as? Bool ?? false,
            email: string(object["email"]),
            orgName: string(object["orgName"]),
            subscriptionType: string(object["subscriptionType"]))
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}
