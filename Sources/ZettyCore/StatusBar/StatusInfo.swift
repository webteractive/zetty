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

/// Decides whether the status bar renders in full or folds into its two pills.
///
/// **Driven by the WINDOW's width, not by leftover space.** The first version
/// compared the space left over beside the left cluster against what the
/// ambient stats needed — but the left cluster holds the working directory and
/// the branch, which change every time an agent runs `cd`. The threshold moved
/// several times a second and the bar visibly flapped between layouts while
/// nothing was being resized. A window width only changes when someone drags
/// the window, which is the only moment either layout should change.
public enum StatusBarCompaction {

    /// Below this content width the ambient stats fold into one pill.
    ///
    /// Derived from what the wide layout actually measures rather than picked:
    /// the ambient group needs ~411pt, the action pills ~140, margins ~50, and
    /// the working directory and git want ~260 between them to stay readable.
    public static let compactBelow: Double = 860

    /// Below this, the working directory and git fold together too. By then
    /// the ambient stats have already gone, so the left cluster has the bar
    /// nearly to itself and still cannot show a readable path beside a branch.
    public static let collapseLeftBelow: Double = 520

    /// How much clear width re-expanding demands beyond the threshold.
    ///
    /// Small, because the threshold no longer moves on its own: this only has
    /// to stop a window parked exactly on the edge from swapping layouts on
    /// every pixel of a drag.
    public static let hysteresis: Double = 16

    /// - Parameters:
    ///   - windowWidth: the status bar's own width, which spans the window's
    ///     content. Stable across content changes, unlike leftover space.
    ///   - wasCompact: the state being replaced, picking which edge of the
    ///     hysteresis band applies.
    public static func isCompact(windowWidth: Double, wasCompact: Bool) -> Bool {
        below(compactBelow, windowWidth: windowWidth, wasInside: wasCompact)
    }

    /// Whether the working directory and git should fold into one pill.
    public static func isLeftCollapsed(windowWidth: Double, wasCollapsed: Bool) -> Bool {
        below(collapseLeftBelow, windowWidth: windowWidth, wasInside: wasCollapsed)
    }

    private static func below(_ threshold: Double,
                              windowWidth: Double,
                              wasInside: Bool) -> Bool {
        // A zero width is a view that has not been laid out yet; treat it as
        // roomy so the bar does not flash its compact form on first paint.
        guard windowWidth > 0 else { return wasInside }
        return wasInside ? windowWidth < threshold + hysteresis : windowWidth < threshold
    }
}
