import Foundation

// MARK: - StatusInfoItem

/// One ambient stat from the status bar's right cluster — the read-mostly
/// information that sits beside the action pills.
///
/// `allCases` order IS display order, both for the wide layout and for the
/// compact chip's rotation; there is deliberately no second ordering field
/// that could disagree with it.
public enum StatusInfoItem: String, CaseIterable, Sendable {
    case appearance
    case scheme
    case shell
    case ghostty
    case version
}

// MARK: - StatusInfoValues

/// The current value behind each ambient stat. Empty means "nothing known
/// yet" — such an item is skipped rather than rendered as a bare prefix.
public struct StatusInfoValues: Equatable, Sendable {
    public var appearance: String
    public var scheme: String
    public var shell: String
    public var ghostty: String
    public var version: String

    public init(appearance: String = "", scheme: String = "", shell: String = "",
                ghostty: String = "", version: String = "") {
        self.appearance = appearance
        self.scheme = scheme
        self.shell = shell
        self.ghostty = ghostty
        self.version = version
    }

    public func value(for item: StatusInfoItem) -> String {
        switch item {
        case .appearance: return appearance
        case .scheme: return scheme
        case .shell: return shell
        case .ghostty: return ghostty
        case .version: return version
        }
    }

    /// The text the compact chip shows for `item`, or `""` when there is no
    /// value. The wide layout can leave the two version numbers unlabelled
    /// because they sit in fixed positions; one chip showing them in turn
    /// cannot, so each carries its product name.
    public func label(for item: StatusInfoItem) -> String {
        let value = value(for: item).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }
        switch item {
        case .ghostty: return "ghostty \(value)"
        case .version: return "zetty \(value)"
        case .appearance, .scheme, .shell: return value
        }
    }

    /// The items that currently have something to show, in display order.
    public var populated: [StatusInfoItem] {
        StatusInfoItem.allCases.filter {
            !value(for: $0).trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

// MARK: - StatusBarCompaction

/// Decides whether the status bar's ambient group has room to render in full,
/// or must fold into the single cycling chip.
public enum StatusBarCompaction {

    /// How much clear space re-expanding demands beyond the bare requirement.
    ///
    /// Without a band, a window parked exactly on the threshold swaps the whole
    /// right cluster back and forth on every pixel of a drag.
    public static let hysteresis: Double = 24

    /// - Parameters:
    ///   - available: leftover width between the left cluster and the trailing
    ///     action pills. May arrive negative mid-resize.
    ///   - required: the ambient group's natural width.
    ///   - wasCompact: the state being replaced, which sets which edge of the
    ///     hysteresis band applies.
    public static func isCompact(available: Double, required: Double, wasCompact: Bool) -> Bool {
        guard required > 0 else { return false }
        return wasCompact ? available < required + hysteresis : available < required
    }
}
