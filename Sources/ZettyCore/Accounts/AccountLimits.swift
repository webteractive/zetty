import Foundation

/// The rate-limit windows last reported for each account.
///
/// A limit belongs to an ACCOUNT, not to a pane: every Claude pane on one
/// login reports the same windows, and the newest report wins. It is persisted
/// so an account still has a figure when no pane is running under it — which
/// is exactly when you are choosing one for a new pane.
public struct AccountLimits: Codable, Equatable, Sendable {

    public struct Window: Codable, Equatable, Sendable {
        /// `five_hour`, `seven_day`, or a gateway's `spend_limit`.
        public let kind: String
        public let percentUsed: Double
        public let resetsAt: Date?

        public init(kind: String, percentUsed: Double, resetsAt: Date? = nil) {
            self.kind = kind
            self.percentUsed = percentUsed
            self.resetsAt = resetsAt
        }

        /// The window as a view shows it: whole percentage points.
        var shown: Window {
            Window(kind: kind, percentUsed: percentUsed.rounded(), resetsAt: resetsAt)
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        var windows: [Window]
        var observedAt: Date
    }

    /// Keyed by account id, `AgentAccountSupport.defaultID` for the default login.
    private(set) var entries: [String: Entry] = [:]

    public init() {}

    /// Records an account's windows and answers whether anything a view shows
    /// changed. A report with NO windows is ignored rather than stored: the
    /// harness reports none before its first response, and that must not wipe
    /// a reading another pane already gave. So is one older than what is held.
    @discardableResult
    public mutating func record(accountID: String, limits: [AgentUsage.RateLimit],
                                observedAt: Date) -> Bool {
        guard !limits.isEmpty else { return false }
        if let held = entries[accountID], held.observedAt > observedAt { return false }
        let windows = limits.map {
            Window(kind: $0.kind, percentUsed: $0.percentUsed, resetsAt: $0.resetsAt)
        }
        let previous = entries[accountID]?.windows.map(\.shown)
        entries[accountID] = Entry(windows: windows, observedAt: observedAt)
        return previous != windows.map(\.shown)
    }

    /// The account's windows that still mean something: one whose reset time
    /// has passed describes a window that no longer exists.
    public func windows(for accountID: String, now: Date) -> [Window] {
        (entries[accountID]?.windows ?? []).filter { window in
            guard let resetsAt = window.resetsAt else { return true }
            return resetsAt > now
        }
    }

    /// Forgets accounts that no longer exist, so a deleted account's reading
    /// cannot resurface under a reused id.
    public mutating func prune(keeping accountIDs: Set<String>) {
        entries = entries.filter { accountIDs.contains($0.key) }
    }
}

/// How an account's limits read in the chrome. Pure: views map `level` onto
/// theme tokens.
public struct AccountLimitLabel: Equatable, Sendable {

    public enum Level: Sendable, Equatable {
        case normal
        case attention
        case critical
    }

    /// The chip stays as it is below this; a limit nobody is near is noise.
    public static let chipFrom = 70.0
    public static let criticalFrom = 95.0
    /// From here a window also says when it resets.
    public static let resetFrom = 90.0

    /// The highest window, `5h 82%` — only once it is worth a glance.
    public let chip: String?
    public let level: Level
    /// Every window, for a menu row: `5h 14% · 7d 12%`, with the reset time on
    /// one that is nearly spent.
    public let summary: String

    /// nil when the account has no live window.
    public init?(windows: [AccountLimits.Window], timeZone: TimeZone = .current) {
        guard !windows.isEmpty else { return nil }
        let ordered = windows.sorted { Self.rank($0.kind) < Self.rank($1.kind) }
        let highest = ordered.max { $0.percentUsed < $1.percentUsed } ?? ordered[0]

        level = highest.percentUsed >= Self.criticalFrom ? .critical
            : highest.percentUsed >= Self.chipFrom ? .attention : .normal
        chip = highest.percentUsed >= Self.chipFrom ? Self.text(highest) : nil
        summary = ordered.map { window in
            guard window.percentUsed >= Self.resetFrom, let resetsAt = window.resetsAt else {
                return Self.text(window)
            }
            return "\(Self.text(window)) (resets \(Self.time(resetsAt, timeZone: timeZone)))"
        }.joined(separator: " · ")
    }

    private static func text(_ window: AccountLimits.Window) -> String {
        "\(shortName(window.kind)) \(Int(window.percentUsed.rounded()))%"
    }

    static func shortName(_ kind: String) -> String {
        switch kind {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        case "spend_limit": return "spend"
        default: return kind
        }
    }

    /// The short window first, then the long one, then anything else by name.
    private static func rank(_ kind: String) -> String {
        switch kind {
        case "five_hour": return "0"
        case "seven_day": return "1"
        default: return "2\(kind)"
        }
    }

    /// `Sun 14:40` — a reset can be days away, so the weekday comes along.
    private static func time(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }
}

/// Load/save for the limits file, mirroring `AgentAccountStore` (same
/// directory, JSON, atomic writes). `load()` returns nothing on ANY failure: a
/// corrupt cache of readings is not worth a failed launch.
public struct AccountLimitsStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("account-limits.json")
    }

    public func load() -> AccountLimits {
        guard let data = try? Data(contentsOf: fileURL),
              let limits = try? JSONDecoder().decode(AccountLimits.self, from: data)
        else { return AccountLimits() }
        return limits
    }

    public func save(_ limits: AccountLimits) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(limits).write(to: fileURL, options: .atomic)
    }
}
