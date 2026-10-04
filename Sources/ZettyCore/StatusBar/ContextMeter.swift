import Foundation

/// The status bar's context-window readout for the focused Claude pane.
/// Pure: `StatusBarView` maps `level` onto theme tokens.
public struct ContextMeter: Equatable, Sendable {

    /// Colour carries meaning (DESIGN rule 8): idle grey, attention, error.
    public enum Level: Sendable, Equatable {
        case normal
        case attention
        case critical
    }

    public static let attentionFrom = 80
    public static let criticalFrom = 95

    public let percent: Int
    public let level: Level
    /// `ctx  5%` — the number is padded to three columns, so in the bar's
    /// mono font the label holds one width while the figure moves.
    public let label: String
    public let tooltip: String

    /// nil when the pane has no reading yet: before the first response the
    /// mod knows the window but not its fill.
    public init?(usage: AgentUsage) {
        guard let percent = usage.contextPercent else { return nil }
        self.percent = percent
        self.level = percent >= Self.criticalFrom ? .critical
            : percent >= Self.attentionFrom ? .attention : .normal
        let figure = String(percent)
        self.label = "ctx " + String(repeating: " ", count: max(0, 3 - figure.count)) + figure + "%"

        var lines = ["Context window \(percent)% full"]
        if let tokens = usage.contextTokens, let window = usage.contextWindow {
            lines[0] += " (\(Self.compact(tokens)) of \(Self.compact(window)) tokens)"
        }
        if let model = usage.model { lines.append(model) }
        if let cost = usage.costUSD {
            lines.append(String(format: "Session cost about $%.2f", cost))
        }
        self.tooltip = lines.joined(separator: "\n")
    }

    /// The row the compact bar's menu shows in the label's place.
    public var menuTitle: String { "Context \(percent)% full" }

    /// `150k`, `1M`, `1.5M` — a token count at the precision a glance needs.
    static func compact(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let millions = Double(tokens) / 1_000_000
            return millions == millions.rounded()
                ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        if tokens >= 1000 { return "\(tokens / 1000)k" }
        return "\(tokens)"
    }
}
